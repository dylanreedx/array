#if ARRAY_CHECKS
import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Witnesses for opening a project file as a tile, and for the Markdown file tile.
///
/// `--file-open-active-context-check` is the behavioral witness for the routing
/// defect this feature repaired: before the fix, opening a file after an in-process
/// workspace switch installed the tile against the DEPARTED zone's placement,
/// appended it to the stale flat `canvasState`, and persisted it through the boot
/// project's store — so the file never appeared in the project the user was looking
/// at, and the wrong project's canvas grew a tile. It drives the same
/// `WorkspaceRuntime.openProjectFile` action Command Center calls.
@MainActor
enum FileOpenChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    // MARK: - Fixture

    private static let sentinelMarkdown = """
    # Sentinel Report

    Opening a file must land in the **active** project, with `inline code` and a
    [link](https://example.com/docs).

    - first item
    - second item

    > quoted line

    ```swift
    let sentinelCode = "fenced-code-sentinel"
    ```

    | a | b |
    | - | - |
    | 1 | 2 |
    """

    private struct Harness {
        let tempRoot: URL
        let runtime: WorkspaceRuntime
        let canvas: CanvasNSView
        let focusBroker: FocusBroker
        let browserEngine: BrowserEngineContext
        let storeA: ProjectStore
        let storeB: ProjectStore
        let rootA: URL
        let rootB: URL
        let zoneB: UUID
        let seededTileA: UUID
        let seededTileB: UUID
    }

    /// Workspace A (project Pa) installed, then switched in-process to workspace B
    /// (project Pb). Nothing is shared between the two projects, so a tile landing
    /// in the wrong one is unambiguous.
    private static func makeSwitchedHarness() throws -> Harness {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let workspaceA = UUID(uuidString: "00000000-0000-0000-0000-0000000F0A01")!
        let workspaceB = UUID(uuidString: "00000000-0000-0000-0000-0000000F0B02")!
        let projectA = UUID(uuidString: "00000000-0000-0000-0000-0000000F0C03")!
        let projectB = UUID(uuidString: "00000000-0000-0000-0000-0000000F0D04")!
        let zoneA = UUID(uuidString: "00000000-0000-0000-0000-0000000F0E05")!
        let zoneB = UUID(uuidString: "00000000-0000-0000-0000-0000000F0F06")!
        let seededTileA = UUID(uuidString: "00000000-0000-0000-0000-0000000F1007")!
        let seededTileB = UUID(uuidString: "00000000-0000-0000-0000-0000000F1108")!

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-file-open-\(UUID().uuidString)", isDirectory: true)
        let rootA = tempRoot.appendingPathComponent("ProjectA", isDirectory: true)
        let rootB = tempRoot.appendingPathComponent("ProjectB", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        try fileManager.createDirectory(at: rootA, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rootB, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)

        try Data(sentinelMarkdown.utf8).write(to: rootB.appendingPathComponent("README.md"))
        try Data("// project A only\n".utf8).write(to: rootA.appendingPathComponent("OnlyInA.swift"))

        func makeProject(id: UUID, name: String, root: URL) -> Project {
            Project(id: id, name: name, rootPath: root.path, createdAt: now, updatedAt: now,
                    defaultLaunchProfileId: "shell", editorPreference: .auto,
                    settings: ProjectSettings(restorePolicy: .restoreDescriptors,
                                              browserStoragePolicy: .perProject,
                                              terminalClosePolicy: .askWhenRunning))
        }
        func seededCanvas(tileId: UUID) -> CanvasState {
            CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                tiles: [Tile(id: tileId, kind: .note, title: "seed",
                             frame: TileFrame(x: 10, y: 10, width: 200, height: 120),
                             zPosition: .fromLegacyRank(1), runtimeRef: nil,
                             metadata: TileMetadata(noteId: tileId))],
                groups: [],
                lastActiveTileId: nil
            )
        }

        let projectAObj = makeProject(id: projectA, name: "ProjectA", root: rootA)
        let projectBObj = makeProject(id: projectB, name: "ProjectB", root: rootB)
        let storeA = ProjectStore(projectRoot: rootA)
        let storeB = ProjectStore(projectRoot: rootB)
        try storeA.saveProject(projectAObj)
        try storeA.saveCanvas(seededCanvas(tileId: seededTileA))
        try storeB.saveProject(projectBObj)
        try storeB.saveCanvas(seededCanvas(tileId: seededTileB))

        func document(zoneId: UUID, projectId: UUID, originX: Double) -> WorkspaceDocument {
            WorkspaceDocument(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                zones: [ZonePlacement(zoneId: zoneId, projectId: projectId,
                                      origin: ZonePoint(x: originX, y: 0),
                                      size: ZoneSize(width: 900, height: 700),
                                      color: "blue", collapsed: false, hydrationPolicy: .automatic)],
                zoneZOrder: [zoneId],
                lastActiveZoneId: zoneId
            )
        }
        // B's zone origin is deliberately NOT (0,0): a tile framed against the wrong
        // zone lands visibly outside B.
        let docA = document(zoneId: zoneA, projectId: projectA, originX: 0)
        let docB = document(zoneId: zoneB, projectId: projectB, originX: 4_000)
        try WorkspaceStore(workspaceId: workspaceA, applicationSupportDirectory: appSupport).save(docA)
        try WorkspaceStore(workspaceId: workspaceB, applicationSupportDirectory: appSupport).save(docB)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceA
        appRegistry.projects = [
            ProjectEntry(id: projectA, name: "ProjectA", rootPath: rootA.path, workspaceId: workspaceA,
                         lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectB, name: "ProjectB", rootPath: rootB.path, workspaceId: workspaceB,
                         lastOpenedAt: now, pinned: false, missing: false)
        ]
        appRegistry.workspaces = [
            WorkspaceEntry(id: workspaceA, name: "A", projectIds: [projectA], createdAt: now, updatedAt: now),
            WorkspaceEntry(id: workspaceB, name: "B", projectIds: [projectB], createdAt: now, updatedAt: now)
        ]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(appRegistry)

        let focusBroker = FocusBroker()
        let browserEngine = BrowserEngineContext()
        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
            if projectId == projectA {
                return ZoneRuntimeController(projectRoot: rootA, projectStore: storeA, project: projectAObj)
            }
            if projectId == projectB {
                return ZoneRuntimeController(projectRoot: rootB, projectStore: storeB, project: projectBObj)
            }
            throw Failure(message: "unexpected projectId in factory: \(projectId)")
        })
        let runtime = WorkspaceRuntime(
            workspaceId: workspaceA, document: docA, registry: zoneRegistry,
            focusBroker: focusBroker, registryStore: registryStore,
            ghostty: nil, browserEngine: browserEngine
        )

        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: false
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        try runtime.install(into: canvas, appRegistry: appRegistry)
        canvas.layoutSubtreeIfNeeded()
        try runtime.switchWorkspace(to: workspaceB)
        canvas.layoutSubtreeIfNeeded()

        return Harness(tempRoot: tempRoot, runtime: runtime, canvas: canvas, focusBroker: focusBroker,
                       browserEngine: browserEngine, storeA: storeA, storeB: storeB,
                       rootA: rootA, rootB: rootB, zoneB: zoneB,
                       seededTileA: seededTileA, seededTileB: seededTileB)
    }

    // MARK: - Section 1: open after an in-process workspace switch

    static func runActiveContextCheck() throws {
        let harness = try makeSwitchedHarness()
        defer {
            harness.browserEngine.shutdown()
            try? FileManager.default.removeItem(at: harness.tempRoot)
        }

        try expect(harness.runtime.activeController?.project.rootPath == harness.rootB.path,
                   "precondition: the active controller after the switch must be project B")
        try expect(harness.runtime.activeController?.tileSpawner != nil,
                   "precondition: the arriving active controller must OWN a spawner (a weak reference deallocated it)")
        try expect(harness.canvas.activeProjectZoneId == harness.zoneB,
                   "precondition: the canvas spawn target must be B's installed zone layer")

        let readme = harness.rootB.appendingPathComponent("README.md").path
        let outcome = harness.runtime.openProjectFile(path: readme)
        guard case let .opened(tileId) = outcome else {
            throw Failure(message: "openProjectFile must report a new tile after a switch; got \(outcome)")
        }
        harness.canvas.layoutSubtreeIfNeeded()

        // 1. A real file tile, visible in B's layer.
        guard let view = harness.canvas.tileView(for: tileId) as? FileTileNSView else {
            throw Failure(message: "the opened tile must be a real FileTileNSView, not a descriptor placeholder")
        }
        try expect(harness.canvas.tileIds(inZone: harness.zoneB).contains(tileId),
                   "the new file tile must belong to B's installed zone layer; layer holds \(harness.canvas.tileIds(inZone: harness.zoneB))")
        try expect(!harness.canvas.canvasState.tiles.contains(where: { $0.id == tileId }),
                   "the new file tile must NOT be appended to the stale flat canvasState after setZones")
        try expect(view.superview === harness.canvas.worldPlane, "the file tile view must be installed in the canvas world plane")
        try expect(view.loadedText?.contains("Sentinel Report") == true,
                   "the file tile must have loaded the sentinel file it was asked to open")
        try expect(view.qaMarkdownDocument?.qaVisibleText().contains("Sentinel Report") == true,
                   "the opened README.md must render its heading in the native Markdown document")

        // 2. Framed inside B's zone, not against A's departed placement.
        guard let placement = harness.canvas.qaZoneLayerPlacement(for: harness.zoneB),
              let tile = harness.canvas.tiles(inZone: harness.zoneB)?.first(where: { $0.id == tileId })
        else { throw Failure(message: "B's zone placement and tile record must both be readable") }
        let world = CanvasEngine.worldFrame(tile: tile, in: placement)
        try expect(world.x >= placement.origin.x && world.x < placement.origin.x + placement.size.width,
                   "the file tile's world frame (\(world)) must fall inside B's zone at origin \(placement.origin)")

        // 3. Persisted in B only.
        guard let persistedB = try harness.storeB.tryLoadCanvas() else {
            throw Failure(message: "project B must have a persisted canvas after the open")
        }
        guard let persistedTile = persistedB.tiles.first(where: { $0.id == tileId }) else {
            throw Failure(message: "project B's persisted canvas must contain the new file tile; it holds \(persistedB.tiles.map(\.id))")
        }
        try expect(persistedTile.kind == .file, "the persisted tile must be a .file tile")
        try expect(persistedTile.metadata.filePath == readme,
                   "the persisted tile must carry the canonical file path; got \(String(describing: persistedTile.metadata.filePath))")
        try expect(persistedB.tiles.contains(where: { $0.id == harness.seededTileB }),
                   "persisting the new tile must not drop B's pre-existing tiles")

        // 4. Project A untouched.
        guard let persistedA = try harness.storeA.tryLoadCanvas() else {
            throw Failure(message: "project A must still have its persisted canvas")
        }
        try expect(persistedA.tiles.map(\.id) == [harness.seededTileA],
                   "project A's persisted canvas must be unchanged; got \(persistedA.tiles.map(\.id))")

        // 5. Focus landed on the new tile.
        try expect(harness.focusBroker.activeSurface == .tile(tileId),
                   "focus must land on the newly opened file tile; got \(String(describing: harness.focusBroker.activeSurface))")

        // 6. Opening the same file again reveals rather than duplicates.
        let second = harness.runtime.openProjectFile(path: readme)
        try expect(second == .revealed(tileId: tileId),
                   "re-opening the same file must reveal the existing tile; got \(second)")
        try expect(harness.canvas.tileIds(inZone: harness.zoneB).filter { $0 == tileId }.count == 1,
                   "re-opening the same file must not add a second tile")

        // 7. A file outside any project still opens where the user asked (the caller
        //    owns validation), but a missing path fails with a user-facing reason.
        let missing = harness.runtime.openProjectFile(path: harness.rootB.appendingPathComponent("nope.md").path)
        guard case let .opened(missingTileId) = missing else {
            throw Failure(message: "a missing file still opens a tile that explains itself; got \(missing)")
        }
        guard let missingView = harness.canvas.tileView(for: missingTileId) as? FileTileNSView else {
            throw Failure(message: "the missing-file tile must still be a FileTileNSView")
        }
        try expect(missingView.loadedText == nil, "a missing file must not report loaded text")
        let empty = harness.runtime.openProjectFile(path: "   ")
        try expect(empty == .failure("That file path is empty."),
                   "an empty path must fail with a user-facing message; got \(empty)")
    }

    // MARK: - Section 4: the rendered document must not re-measure on every layout

    /// A Markdown tile lays out whenever the canvas does — every pan, zoom, tile
    /// move and appearance flip. Measuring a block is NOT cheap: prose builds a
    /// fresh attributed string per row, and a fenced block (which is where a GFM
    /// table lands) measures its entire source at unbounded width. Re-measuring
    /// every block on every pass froze the app on a real repo document.
    /// Exercise the owner's replaceDraft + previewBody sequence, not just a
    /// document relayout. Stable input must preserve the native text systems.
    private static func runUnchangedMarkdownSurfaceCheck() throws {
        let source = (0..<100).map { "Surface item \($0): **unchanged** draft content." }
            .joined(separator: "\n\n")
        let text = NSTextView()
        text.string = source
        let scroll = NSScrollView()
        scroll.documentView = text
        var theme: TokenTheme = .dark
        let surface = MarkdownDocumentSurface(
            textView: text, sourceScrollView: scroll, initialDraft: source,
            mode: .preview, theme: { theme }
        )
        // Loading before first mounting must still render the initial draft.
        surface.replaceDraft(source)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 460))
        let body = surface.previewBody()
        body.frame = host.bounds
        host.addSubview(body)
        guard let preview = surface.previewView else {
            throw Failure(message: "Markdown surface failed to create its preview")
        }
        func settle() {
            host.layoutSubtreeIfNeeded()
            preview.layoutSubtreeIfNeeded()
            preview.qaRelayout()
        }
        settle()
        try expect(preview.qaBlockViews.count == 100 && preview.qaVisibleText().contains("Surface item 99"),
                   "initial Markdown surface did not render the complete draft")
        let blocks = preview.qaBlockViews
        let measurements = preview.qaMeasurementCount
        let start = ProcessInfo.processInfo.systemUptime
        surface.replaceDraft(source)
        _ = surface.previewBody()
        surface.flushPreview()
        settle()
        let added = preview.qaMeasurementCount - measurements
        print("markdown unchanged surface: 100 blocks, measurements=\(added), duration=\(ProcessInfo.processInfo.systemUptime - start)s")
        try expect(added == 0, "unchanged owner refresh measured \(added) blocks; expected zero")
        try expect(preview.qaBlockViews.count == blocks.count
                   && zip(blocks, preview.qaBlockViews).allSatisfy { $0 === $1 },
                   "unchanged owner refresh replaced native block views")

        let changed = source + "\n\nChanged draft sentinel."
        surface.replaceDraft(changed)
        settle()
        try expect(preview.qaVisibleText().contains("Changed draft sentinel.")
                   && preview.qaMeasurementCount > measurements,
                   "changed Markdown draft was hidden by the refresh cache")
        for nextTheme in [TokenTheme.light, .dark] {
            let before = preview.qaMeasurementCount
            theme = nextTheme
            // A changed theme supplied by the owner must invalidate the cache.
            _ = surface.previewBody()
            settle()
            try expect(preview.qaMeasurementCount > before,
                       "changed theme did not invalidate Markdown measurements")
            let renderedColor = preview.qaInlineTextViews().first?.textStorage?
                .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            let expectedColor = AgentRenderTokens.transcript.primaryText.color.nsColor(for: nextTheme)
            try expect(renderedColor?.usingColorSpace(.sRGB) == expectedColor.usingColorSpace(.sRGB),
                       "Markdown refresh did not paint the requested theme")
            let themedBlocks = preview.qaBlockViews
            surface.applyTheme()
            settle()
            let afterTheme = preview.qaMeasurementCount
            _ = surface.previewBody()
            settle()
            try expect(preview.qaMeasurementCount == afterTheme
                       && zip(themedBlocks, preview.qaBlockViews).allSatisfy { $0 === $1 },
                       "owner theme application caused a duplicate preview rebuild")
            try expect(preview.qaVisibleText().contains("Changed draft sentinel."),
                       "theme update lost the current Markdown draft")
        }
        // A changed theme applied explicitly must also become the cached theme.
        theme = .light
        let themeBlocks = preview.qaBlockViews
        surface.applyTheme()
        settle()
        let themedMeasurements = preview.qaMeasurementCount
        _ = surface.previewBody()
        settle()
        let explicitColor = preview.qaInlineTextViews().first?.textStorage?
            .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        try expect(explicitColor?.usingColorSpace(.sRGB)
                   == AgentRenderTokens.transcript.primaryText.color.nsColor(for: .light).usingColorSpace(.sRGB)
                   && preview.qaMeasurementCount == themedMeasurements
                   && zip(themeBlocks, preview.qaBlockViews).allSatisfy { $0 === $1 },
                   "explicit theme update was lost or followed by a duplicate preview rebuild")
        // Source-only edits must catch up on the first Preview mount.
        surface.setMode(.edit)
        let edited = changed + "\n\nEdited while source-only."
        surface.replaceDraft(edited)
        surface.setMode(.preview, sourceDraft: edited)
        _ = surface.previewBody()
        settle()
        try expect(preview.qaVisibleText().contains("Edited while source-only."),
                   "returning from Edit reused a stale preview")

        // Canonically equivalent Unicode can spell different link destinations.
        // A render key must preserve their literal bytes, not String == equality.
        let destinations = ["https://example.com/Cafe\u{301}", "https://example.com/Caf\u{e9}"]
        try expect(destinations[0] == destinations[1]
                   && !destinations[0].utf8.elementsEqual(destinations[1].utf8),
                   "Unicode render-key fixture must be canonically equal but byte-distinct")
        for destination in destinations {
            surface.replaceDraft("[open](\(destination))")
            surface.flushPreview()
            settle()
            let actual = preview.qaInlineTextViews().flatMap(\.linkRanges).first?.destination
            try expect(actual.map { $0.utf8.elementsEqual(destination.utf8) } == true,
                       "Markdown refresh retained stale Unicode link destination bytes")
        }
    }

    /// A real code block stays native while selected or streaming. A camera
    /// backing/layout pass must not reshape its unchanged, nonwrapping source.
    private static func runUnchangedCodeBlockLayoutCheck() throws {
        guard let blockID = AgentNodeID(rawValue: "code-layout-measurement") else {
            throw Failure(message: "could not create code-layout fixture identity")
        }
        let source = (0..<64).map {
            "\($0):\tlet value = \"\(String(repeating: "wide", count: 48))\" // Cafe\u{301}"
        }.joined(separator: "\n")
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 320))
        let block = CodeBlockView(highlighter: PlainCodeHighlighter())
        block.frame = host.bounds
        host.addSubview(block)
        var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        func layoutBlock() {
            block.needsLayout = true
            block.layoutSubtreeIfNeeded()
        }
        func apply(_ code: String) {
            block.apply(blockID: blockID,
                        payload: AgentCodePayload(language: "swift", code: code, isComplete: true),
                        context: context)
            layoutBlock()
        }
        @MainActor func expectCurrentContentAndGeometry(_ code: String) throws {
            // The uncached primitive is an oracle for stale cache entries.
            // Its intentional measurement is outside every work-count interval.
            let measured = CodeTextView.measuredCodeSize(code, zoom: context.pageZoom)
            let viewport = block.scrollView.contentSize
            let expected = NSSize(width: max(viewport.width, measured.width),
                                  height: max(viewport.height, measured.height))
            let actual = block.codeTextView.frame.size
            try expect(abs(actual.width - expected.width) < 0.5
                       && abs(actual.height - expected.height) < 0.5,
                       "code document geometry used stale content or font metrics: \(actual) vs \(expected)")
            try expect(block.scrollView.hasVerticalScroller == (measured.height > viewport.height + 0.5),
                       "code block vertical scrolling does not match its current content")
            let font = block.codeTextView.textStorage?
                .attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let expectedFontSize = NSFont.token(.bodyMono, zoom: context.pageZoom).pointSize
            try expect(font?.pointSize == expectedFontSize,
                       "code text did not paint the current page-zoom font")
            block.copyEntireBlock(to: pasteboard)
            try expect(pasteboard.string(forType: .string).map { $0.utf8.elementsEqual(code.utf8) } == true,
                       "code layout truncated or changed copied source bytes")
        }

        apply(source)
        try expectCurrentContentAndGeometry(source)
        try expect(block.scrollView.hasVerticalScroller
                   && block.codeTextView.frame.width > block.scrollView.contentSize.width,
                   "code fixture must overflow both axes")
        let selection = NSRange(location: 5, length: 8)
        block.codeTextView.setSelectedRange(selection)
        block.scrollView.contentView.scroll(to: NSPoint(x: 23, y: 120))
        block.scrollView.reflectScrolledClipView(block.scrollView.contentView)
        let scrollOrigin = block.scrollView.contentView.bounds.origin
        let beforeStable = CodeTextView.qaUnwrappedMeasurementCount
        for _ in 0..<10 { layoutBlock() }
        let stableMeasurements = CodeTextView.qaUnwrappedMeasurementCount - beforeStable
        try expect(block.codeTextView.selectedRange() == selection
                   && block.scrollView.contentView.bounds.origin == scrollOrigin,
                   "unchanged code layout moved selection or scroll position")
        try expectCurrentContentAndGeometry(source)

        // Shrinking source must discard its old wide/tall geometry and scroller.
        let replacement = "let tiny = 1"
        let beforeContentChange = CodeTextView.qaUnwrappedMeasurementCount
        apply(replacement)
        let contentMeasurements = CodeTextView.qaUnwrappedMeasurementCount - beforeContentChange
        try expect(contentMeasurements > 0, "changed code content never refreshed its dimensions")
        try expectCurrentContentAndGeometry(replacement)
        try expect(!block.scrollView.hasVerticalScroller,
                   "shrinking code retained a stale vertical scroller")

        // Page zoom changes the real font and insets without changing the source.
        apply(source)
        var zoomMeasurements: [Int] = []
        for percent in [150, 80] {
            context.pageZoom = AgentPageZoom(percent: percent)
            let beforeZoom = CodeTextView.qaUnwrappedMeasurementCount
            apply(source)
            let changed = CodeTextView.qaUnwrappedMeasurementCount - beforeZoom
            zoomMeasurements.append(changed)
            try expect(changed > 0, "page zoom \(percent)% never refreshed code dimensions")
            try expectCurrentContentAndGeometry(source)
        }
        print("code block layout: 10 unchanged passes measured \(stableMeasurements); content change \(contentMeasurements); page zoom \(zoomMeasurements)")
        try expect(stableMeasurements == 0,
                   "10 unchanged code-block layouts must perform zero unwrapped measurements; performed \(stableMeasurements)")
    }

    /// Hydration creates prose before the tile supplies its first real width.
    /// Unsized layout must leave native text geometry alone, then render normally
    /// when mounted. A small paragraph witnesses the work without a stress load.
    private static func runUnsizedProseLayoutCheck() throws {
        let source = String(
            repeating: "Initial prose needs real width before shaping, while selection and copied text stay complete. ",
            count: 3
        )
        let prose = AssistantProseView(frame: .zero)
        let beforeApply = AssistantProseView.qaMeasurementCount
        prose.apply(
            block: AgentBlock(
                id: AgentNodeID(rawValue: "prose-unsized-hydration")!,
                revision: 1,
                kind: .paragraph,
                payload: .paragraph([.text(source)])
            ),
            context: AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
        )
        try expect(prose.textFields.count == 1, "unsized prose fixture must create one native text row")
        for _ in 0..<10 {
            prose.needsLayout = true
            prose.layoutSubtreeIfNeeded()
        }
        let unsizedMeasurements = AssistantProseView.qaMeasurementCount - beforeApply
        let unsizedFrames = prose.textFields.map(\.frame)
        print("prose unsized hydration: chars=\(source.utf16.count), passes=10, measurements=\(unsizedMeasurements), childFrames=\(unsizedFrames)")

        let text = prose.textFields[0]
        let selection = NSRange(location: 8, length: 35)
        text.setSelectedRange(selection)
        let beforeMount = AssistantProseView.qaMeasurementCount
        prose.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        prose.needsLayout = true
        prose.layoutSubtreeIfNeeded()
        let mountedMeasurements = AssistantProseView.qaMeasurementCount - beforeMount
        let mountedFrame = text.frame
        print("prose mounted hydration: measurements=\(mountedMeasurements), childFrame=\(mountedFrame)")
        try expect(mountedMeasurements > 0,
                   "giving unsized prose a real width must perform an actual text measurement")
        try expect(text.string.utf8.elementsEqual(source.utf8),
                   "mounting previously unsized prose lost or changed source text")
        try expect(mountedFrame.width == 320 && mountedFrame.height.isFinite && mountedFrame.height > 0
                   && mountedFrame.origin.x.isFinite && mountedFrame.origin.y.isFinite,
                   "mounted prose did not receive finite, positive geometry: \(mountedFrame)")
        let usedRect = text.qaUsedRectForChecks
        try expect(usedRect.map { $0.height.isFinite && $0.height > 0 && $0.maxY <= mountedFrame.height + 0.5 } == true,
                   "mounted prose geometry clipped its actual native text layout")
        try expect(text.selectedRange() == selection,
                   "first real prose layout changed the native selection")
        // Copy routing is covered by the document selection witness below.

        try expect(unsizedMeasurements == 0,
                   "10 zero-width prose layouts must perform zero row measurements; performed \(unsizedMeasurements)")
        try expect(unsizedFrames.allSatisfy { $0 == .zero },
                   "zero-width prose assigned premature child geometry: \(unsizedFrames)")
    }

    static func runMarkdownPerformanceCheck() throws {
        try runUnsizedProseLayoutCheck()
        try runUnchangedMarkdownSurfaceCheck()
        try runUnchangedCodeBlockLayoutCheck()
        let document = perfFixture()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let view = FileMarkdownDocumentView(frame: NSRect(x: 0, y: 0, width: 620, height: 460))
        host.addSubview(view)

        let renderStart = ProcessInfo.processInfo.systemUptime
        view.apply(markdown: document, theme: .dark)
        view.layoutSubtreeIfNeeded()
        let renderSeconds = ProcessInfo.processInfo.systemUptime - renderStart

        let blocks = view.qaBlockViews.count
        try expect(blocks > 40, "the performance fixture must produce a realistically large document; got \(blocks) blocks")
        try expect(view.qaVisibleText().contains("perf-sentinel"),
                   "the performance fixture must actually render its content")

        // Rendered Markdown is many native text systems. A document selection
        // must bridge them and copy as one ordered range, rather than stopping at
        // the first paragraph boundary.
        let selectionViews = view.richInlineTextViewsInSelectionOrder()
        try expect(selectionViews.count >= 3, "Markdown selection fixture rendered fewer than three prose rows")
        let selectionSource = selectionViews[0]
        let selectionMiddle = selectionViews[1]
        let selectionTarget = selectionViews[2]
        let sourceLength = (selectionSource.string as NSString).length
        let targetLength = (selectionTarget.string as NSString).length
        selectionSource.qaExtendSelection(
            to: selectionTarget, anchor: min(1, sourceLength),
            targetCharacter: min(2, targetLength)
        )
        try expect(selectionSource.selectedRange().length == max(0, sourceLength - min(1, sourceLength))
                   && selectionMiddle.selectedRange().length == (selectionMiddle.string as NSString).length
                   && selectionTarget.selectedRange().length == min(2, targetLength),
                   "Markdown document selection did not cross sibling text views")
        selectionSource.copy(nil)
        let copiedSelection = NSPasteboard.general.string(forType: .string) ?? ""
        try expect(copiedSelection.contains("\n") && !copiedSelection.isEmpty,
                   "Markdown document-wide selection did not copy as one ordered range")
        selectionViews.forEach { $0.setSelectedRange(NSRange(location: 0, length: 0)) }

        // Exercise the real AppKit tracking path. NSTextView consumes the drag
        // inside `mouseDown`; RichInlineTextView must resume after that loop and
        // extend the selection into the sibling under the release point.
        let eventWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let eventDocument = FileMarkdownDocumentView(frame: eventWindow.contentView?.bounds ?? .zero)
        eventWindow.contentView = eventDocument
        eventDocument.apply(markdown: "First selectable paragraph.\n\nSecond selectable paragraph.", theme: .dark)
        eventWindow.contentView?.layoutSubtreeIfNeeded()
        eventDocument.layoutSubtreeIfNeeded()
        let eventViews = eventDocument.richInlineTextViewsInSelectionOrder()
        try expect(eventViews.count == 2, "event selection fixture did not render two Markdown paragraphs")
        let downPoint = eventViews[0].convert(
            NSPoint(x: min(8, eventViews[0].bounds.maxX), y: eventViews[0].bounds.midY), to: nil
        )
        let targetPoint = eventViews[1].convert(
            NSPoint(x: max(8, eventViews[1].bounds.maxX * 0.6), y: eventViews[1].bounds.midY), to: nil
        )
        func mouseEvent(_ type: NSEvent.EventType, point: NSPoint, number: Int) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: eventWindow.windowNumber, context: nil,
                eventNumber: number, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else { throw Failure(message: "could not create Markdown selection event \(type)") }
            return event
        }
        let down = try mouseEvent(.leftMouseDown, point: downPoint, number: 1)
        let drag = try mouseEvent(.leftMouseDragged, point: targetPoint, number: 2)
        let up = try mouseEvent(.leftMouseUp, point: targetPoint, number: 3)
        NSApplication.shared.postEvent(drag, atStart: false)
        NSApplication.shared.postEvent(up, atStart: false)
        eventViews[0].mouseDown(with: down)
        try expect(eventViews.allSatisfy({ $0.selectedRange().length > 0 }),
                   "real Markdown mouse drag still stopped at the first rendered paragraph")

        // What a canvas pan/zoom actually does to a tile: reposition it and lay it
        // out again. The document did not change and its width did not change, so
        // this must cost no measurement at all.
        let measurementsAfterRender = view.qaMeasurementCount
        let panStart = ProcessInfo.processInfo.systemUptime
        for step in 0..<30 {
            host.frame = NSRect(x: CGFloat(step), y: CGFloat(step), width: 900, height: 700)
            view.frame = NSRect(x: CGFloat(step), y: 0, width: 620, height: 460)
            view.qaRelayout()
        }
        let panSeconds = ProcessInfo.processInfo.systemUptime - panStart
        let panMeasurements = view.qaMeasurementCount - measurementsAfterRender

        // **The sub-pixel jiggle a camera zoom actually produces.** Pixel snapping
        // at the effective scale re-rounds interior widths by up to one device
        // pixel per zoom step — a live gesture log measured 599.6 -> 600.9 -> 600.3
        // -> 599.1, and the old 0.5 pt guard re-measured the whole document for
        // each: 4,310 prose measurements in one 8-step gesture, 569 ms per frame,
        // "zooming is horrendous". Widths inside the hysteresis band must measure
        // NOTHING.
        let jiggleBase = view.qaMeasurementCount
        for delta in [CGFloat(1.3), -0.6, -1.2, 1.0, -1.3, 0.9] {
            view.frame = NSRect(x: 0, y: 0, width: 620 + delta, height: 460)
            view.layoutSubtreeIfNeeded()
            view.qaRelayout()
        }
        let jiggleMeasurements = view.qaMeasurementCount - jiggleBase
        try expect(jiggleMeasurements == 0,
                   "sub-pixel width jiggle (the camera-zoom snap, ±1.3 pt) re-measured "
                   + "\(jiggleMeasurements) block(s); the hysteresis is not holding")
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 460)
        view.layoutSubtreeIfNeeded()
        view.qaRelayout()

        // A width change is the one thing that legitimately re-measures.
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 460)
        view.layoutSubtreeIfNeeded()
        view.qaRelayout()
        let resizeMeasurements = view.qaMeasurementCount - measurementsAfterRender - panMeasurements

        print("markdown perf: \(blocks) blocks, first render \(String(format: "%.3f", renderSeconds))s, 30 same-width relayouts \(String(format: "%.3f", panSeconds))s, measurements render=\(measurementsAfterRender) pan=\(panMeasurements) resize=\(resizeMeasurements)")

        try expect(panMeasurements == 0,
                   "30 same-width relayouts must re-measure NOTHING; they measured \(panMeasurements) block(s)")
        // ~16ms per FORCED full-subtree relayout of 183 blocks is AppKit laying out
        // 183 TextKit stacks, not this view re-deciding anything — the measurement
        // count above is the assertion with teeth. This is the coarse guard that
        // notices a return to per-pass measuring, with 2x headroom over measured.
        try expect(panSeconds < 1.0,
                   "30 same-width relayouts must stay under 1s; took \(String(format: "%.3f", panSeconds))s")
        try expect(resizeMeasurements > 0 && resizeMeasurements <= blocks,
                   "a width change must re-measure each block exactly once; it measured \(resizeMeasurements) for \(blocks) blocks")
        try expect(renderSeconds < 2.0,
                   "the first render of a large document must stay under 2s; took \(String(format: "%.3f", renderSeconds))s")
        try expect(view.qaTruncatedBlockCount == 0,
                   "a document of \(blocks) blocks must render in full, not truncate")

        // The transcript's prose renderer shares both the anti-pattern and the fix,
        // and it was the LARGER half of the measured cost (30,000 CoreText samples,
        // most attributed to `AssistantProseView.layout()`), so it is witnessed
        // here beside the markdown case rather than trusted by analogy.
        let prose = AssistantProseView(frame: NSRect(x: 0, y: 0, width: 620, height: 200))
        prose.apply(
            block: AgentBlock(
                id: AgentNodeID(rawValue: "prose-hysteresis")!,
                revision: 1,
                kind: .paragraph,
                payload: .paragraph([.text(String(
                    repeating: "A sentence long enough to wrap several times at this width. ", count: 8
                ))])
            ),
            context: AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
        )
        prose.layoutSubtreeIfNeeded()
        let proseBase = AssistantProseView.qaMeasurementCount
        for delta in [CGFloat(1.3), -0.6, -1.2, 1.0, -1.3, 0.9] {
            prose.frame = NSRect(x: 0, y: 0, width: 620 + delta, height: 200)
            prose.needsLayout = true
            prose.layoutSubtreeIfNeeded()
        }
        let proseJiggle = AssistantProseView.qaMeasurementCount - proseBase
        try expect(proseJiggle == 0,
                   "prose re-measured \(proseJiggle) row(s) for a sub-pixel width jiggle; "
                   + "the hysteresis is not holding")
        prose.frame = NSRect(x: 0, y: 0, width: 520, height: 200)
        prose.needsLayout = true
        prose.layoutSubtreeIfNeeded()
        try expect(AssistantProseView.qaMeasurementCount > proseBase,
                   "a REAL width change must still re-measure prose, or the cache is dead rather than lazy")

        // The file loader admits up to 1 MB. Un-budgeted, a 546 KB Markdown file
        // built 12,000 TextKit views: 5.1s to build, 5.1s to lay out, 1.39 GB
        // resident — the app froze and then died. Preview is now bounded and says
        // where it stopped.
        let hugeHost = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let huge = FileMarkdownDocumentView(frame: NSRect(x: 0, y: 0, width: 620, height: 460))
        hugeHost.addSubview(huge)
        let hugeSource = hugeFixture()
        let hugeStart = ProcessInfo.processInfo.systemUptime
        huge.apply(markdown: hugeSource, theme: .dark)
        huge.layoutSubtreeIfNeeded()
        let hugeSeconds = ProcessInfo.processInfo.systemUptime - hugeStart
        let budget = FileMarkdownDocumentView.maximumRenderedBlocks
        print("markdown perf: \(hugeSource.count) chars rendered as \(huge.qaBlockViews.count) view(s) in \(String(format: "%.3f", hugeSeconds))s, \(huge.qaTruncatedBlockCount) block(s) held back")
        try expect(huge.qaBlockViews.count <= budget + 1,
                   "a huge document must render at most \(budget) blocks plus one notice; it built \(huge.qaBlockViews.count) views")
        try expect(huge.qaTruncatedBlockCount > 1_000,
                   "the huge fixture must actually exceed the budget; only \(huge.qaTruncatedBlockCount) block(s) were held back")
        try expect(huge.qaVisibleText().contains("Switch to Source"),
                   "a truncated preview must SAY it stopped and point at Source")
        try expect(hugeSeconds < 1.5,
                   "a huge document must still open in under 1.5s; took \(String(format: "%.3f", hugeSeconds))s")

        try runMarkdownLayoutSettlesCheck()
    }

    /// The document must SETTLE. Sizing a view from inside its own `layout()`
    /// makes AppKit re-enter layout on that subtree, and each re-entry re-measured
    /// every block: Dylan's 0.4.15 hang report is 75.48 seconds with 53 nested
    /// `_layoutSubtreeWithOldSize:` frames, the main thread inside
    /// `FileMarkdownDocumentView.BodyView.layout()` → `AssistantProseRenderer.measure`
    /// → `AgentTextStyleResolver.append` → `replacingOccurrences`. Height now comes
    /// from `intrinsicContentSize`, so a real window layout converges.
    /// With a mouse paired, every WKWebView layer commit makes AppKit rewrite all
    /// scroll views to legacy style. Legacy scrollers took 17 pt from the clip,
    /// every Markdown document re-measured at the new width, and 24 tiles stalled
    /// the main thread for seconds. Calls that AppKit entry point directly, on a
    /// real file tile, so the flip does not depend on web-process timing.
    static func runMarkdownScrollerStyleCheck() throws {
        guard let pairs = NSClassFromString("NSScrollerImpPair"),
              let method = class_getClassMethod(
                  pairs, NSSelectorFromString("_updateAllScrollerImpPairsForNewRecommendedScrollerStyle:")
              ) else {
            throw Failure(message: "AppKit no longer has the scroller style entry point this check drives")
        }
        typealias Update = @convention(c) (AnyClass, Selector, Int) -> Void
        let update = unsafeBitCast(method_getImplementation(method), to: Update.self)
        let flip: (NSScroller.Style) -> Void = {
            update(pairs, method_getName(method), $0.rawValue)
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-file-markdown-scroller-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let url = root.appendingPathComponent("README.md")
        try Data(perfFixture().utf8).write(to: url)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = host
        window.orderFrontOffscreenForChecks()
        let tile = Tile(id: UUID(), kind: .file, title: "README.md",
                        frame: TileFrame(x: 0, y: 0, width: 620, height: 460),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil,
                        metadata: TileMetadata(filePath: url.path))
        let view = FileTileNSView(tile: tile)
        view.frame = NSRect(x: 10, y: 10, width: 620, height: 460)
        host.addSubview(view)
        view.layoutSubtreeIfNeeded()
        guard let document = view.qaMarkdownDocument,
              let scrollView = document.subviews.compactMap({ $0 as? NSScrollView }).first,
              let body = scrollView.documentView else {
            throw Failure(message: "the file tile must install the native Markdown document")
        }
        // Control: an ordinary scroll view must follow the flip, or the flip did
        // not happen and everything below would pass for nothing.
        let control = NSScrollView(frame: NSRect(x: 640, y: 10, width: 240, height: 200))
        control.hasVerticalScroller = true
        control.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 2_000))
        host.addSubview(control)

        func settle() {
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            document.layoutSubtreeIfNeeded()
        }
        flip(.overlay)
        settle()
        try expect(document.qaDocumentHeight > document.qaClipHeight,
                   "the document must overflow, or no scroller could ever take width")
        let width = body.frame.width
        let clipWidth = scrollView.contentView.bounds.width
        let documentMeasurements = document.qaMeasurementCount
        let proseMeasurements = AssistantProseView.qaMeasurementCount
        try expect(width > 0 && documentMeasurements > 0, "the document must have been measured before the flip")

        for style in [NSScroller.Style.legacy, .overlay, .legacy] {
            flip(style)
            settle()
            let name = style == .legacy ? "legacy" : "overlay"
            try expect(control.scrollerStyle == style, "\(name): AppKit did not flip the control scroll view")
            try expect(body.frame.width == width && scrollView.contentView.bounds.width == clipWidth,
                       "\(name): the scroller moved the text width: document \(width) -> \(body.frame.width), clip \(clipWidth) -> \(scrollView.contentView.bounds.width)")
            try expect(document.qaMeasurementCount == documentMeasurements
                       && AssistantProseView.qaMeasurementCount == proseMeasurements,
                       "\(name): a scroller style change re-measured the document: blocks \(document.qaMeasurementCount - documentMeasurements), prose rows \(AssistantProseView.qaMeasurementCount - proseMeasurements)")
        }
        flip(.overlay)
        // Mouse users keep a scroller, and the document still scrolls.
        try expect(scrollView.hasVerticalScroller && scrollView.verticalScroller?.isEnabled == true,
                   "the overflowing document lost its vertical scroller")
        document.qaScroll(toY: 200)
        settle()
        try expect(document.qaScrollOffsetY == 200, "the document must still scroll after the flips")
    }

    static func runMarkdownLayoutSettlesCheck() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        guard let content = window.contentView else {
            throw Failure(message: "the window must have a content view")
        }
        let view = FileMarkdownDocumentView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        // Legacy scrollers are the hostile case and the one a check on a laptop
        // never sees by default: they STEAL clip width when they appear, so a
        // document that sizes itself from its own layout can toggle the scroller
        // forever. macOS picks this style whenever a mouse is connected.
        if let scrollView = view.subviews.compactMap({ $0 as? NSScrollView }).first {
            scrollView.scrollerStyle = .legacy
        }
        view.apply(markdown: perfFixture(), theme: .dark)
        content.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let settledLayouts = view.qaLayoutCount
        let settledMeasurements = view.qaMeasurementCount
        let blocks = view.qaBlockViews.count

        try expect(view.qaDocumentHeight > view.qaClipHeight,
                   "the fixture must be tall enough to scroll (document \(view.qaDocumentHeight) vs clip \(view.qaClipHeight))")
        try expect(settledLayouts <= 8,
                   "a real window layout must settle in a handful of passes; the body laid out \(settledLayouts) times")
        try expect(settledMeasurements <= blocks * 2,
                   "settling must not re-measure the document repeatedly; \(blocks) blocks were measured \(settledMeasurements) times")

        // Heights that straddle the clip height are where a scroller that steals
        // width oscillates forever. Walk the window across that boundary.
        for height in stride(from: 320.0, through: 900.0, by: 20.0) {
            window.setContentSize(NSSize(width: 640, height: height))
            content.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
        }
        let sweepLayouts = view.qaLayoutCount - settledLayouts
        let sweepMeasurements = view.qaMeasurementCount - settledMeasurements
        print("markdown layout: \(blocks) blocks settled in \(settledLayouts) layout(s)/\(settledMeasurements) measurement(s); 30-step height sweep cost \(sweepLayouts) layout(s)/\(sweepMeasurements) measurement(s)")

        try expect(sweepLayouts <= 120,
                   "a 30-step height sweep must cost a bounded number of layouts; it cost \(sweepLayouts)")
        // A legacy scroller appearing changes the clip WIDTH once, which is a
        // legitimate re-measure. What must not happen is measuring per pass.
        try expect(sweepMeasurements <= blocks,
                   "a height sweep may re-measure at most once (a scroller taking width); it measured \(sweepMeasurements) for \(blocks) blocks")

        // The document view is only half of it: each prose block re-measured its own
        // rows and re-assigned its text view frames on every layout pass. A 0.4.16
        // CPU report on a Markdown tile burned 90s at 96% CPU with 20 of 34 samples
        // inside AssistantProseView.layout().
        let proseBefore = AssistantProseView.qaMeasurementCount
        for _ in 0..<20 {
            view.qaRelayout()
            content.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
        }
        let proseMeasurements = AssistantProseView.qaMeasurementCount - proseBefore
        print("markdown layout: 20 further relayouts cost \(proseMeasurements) prose row measurement(s)")
        try expect(proseMeasurements == 0,
                   "20 relayouts at an unchanged width must cost NO prose row measurement; they cost \(proseMeasurements)")
    }

    /// ~550 KB of ordinary Markdown — well inside the loader's 1 MB ceiling.
    private static func hugeFixture() -> String {
        (0..<4_000).map { index in
            "## Section \(index)\n\nProse with `code`, **strong** text and a [link](https://example.com/\(index)).\n\n- item a\n- item b\n"
        }.joined(separator: "\n")
    }

    /// Shaped like the documents that froze: long prose, a fenced block, and a
    /// wide GFM table (which the parser renders as one monospace fallback block
    /// whose source measures at unbounded width).
    private static func perfFixture() -> String {
        var lines: [String] = ["# perf-sentinel", ""]
        for index in 0..<60 {
            lines.append("## Section \(index)")
            lines.append("")
            lines.append(String(repeating: "Prose with `code`, **strong** text and a [link](https://example.com/\(index)). ", count: 8))
            lines.append("")
            lines.append("- item one for \(index)")
            lines.append("- item two for \(index)")
            lines.append("")
        }
        lines.append("| version | build | notes |")
        lines.append("| ------- | ----- | ----- |")
        for index in 0..<20 {
            lines.append("| 0.\(index).0 | \(index) | \(String(repeating: "a long ledger note that never wraps ", count: 60)) |")
        }
        lines.append("")
        lines.append("```swift")
        lines.append(String(repeating: "let padding = \"wide\"  // \(String(repeating: "x", count: 200))\n", count: 40))
        lines.append("```")
        return lines.joined(separator: "\n")
    }

    private static func checkDocumentRelationshipGeometry() throws {
        typealias Segment = DocumentRelationshipOverlayView.Segment
        func cubic(_ source: CGRect, _ target: CGRect, label: String) throws
            -> (CGPoint, CGPoint, CGPoint, CGPoint) {
            guard case let .cubic(start, control1, control2, end)? =
                DocumentRelationshipOverlayView.route(for: Segment(source: source, target: target, emphasized: false))
            else { throw Failure(message: "\(label) did not produce a cubic route") }
            try expect([start, control1, control2, end].flatMap { [$0.x, $0.y] }.allSatisfy(\.isFinite),
                       "\(label) produced non-finite geometry")
            return (start, control1, control2, end)
        }

        for gap in [CGFloat(8), 20, 180] {
            let source = CGRect(x: 20, y: 40, width: 100, height: 80)
            let target = CGRect(x: source.maxX + gap, y: 95, width: 120, height: 90)
            let route = try cubic(source, target, label: "\(Int(gap))pt right gap")
            try expect(route.0.x == source.maxX && route.3.x == target.minX,
                       "\(Int(gap))pt route did not use facing horizontal edges")
            try expect(route.1.x >= route.0.x && route.1.x <= route.3.x
                        && route.2.x >= route.0.x && route.2.x <= route.3.x,
                       "\(Int(gap))pt handles escaped the visible gap")
        }

        let leftDocument = try cubic(
            CGRect(x: 260, y: 40, width: 100, height: 80),
            CGRect(x: 120, y: 90, width: 120, height: 90), label: "document left")
        try expect(leftDocument.0.x == 260 && leftDocument.3.x == 240
                    && leftDocument.1.x <= leftDocument.0.x && leftDocument.2.x >= leftDocument.3.x,
                   "document-left route did not reverse its facing edges and handles")

        let vertical = try cubic(
            CGRect(x: 80, y: 20, width: 120, height: 80),
            CGRect(x: 110, y: 120, width: 120, height: 80), label: "vertical gap")
        try expect(vertical.0.y == 100 && vertical.3.y == 120,
                   "vertically separated tiles did not use facing vertical edges")

        let overlapSource = CGRect(x: 80, y: 80, width: 160, height: 120)
        let overlapTarget = CGRect(x: 180, y: 130, width: 160, height: 120)
        guard case let .polyline(points)? = DocumentRelationshipOverlayView.route(for: Segment(
            source: overlapSource, target: overlapTarget, emphasized: false)) else {
            throw Failure(message: "overlapping tiles did not use the outside-union route")
        }
        let union = overlapSource.union(overlapTarget)
        try expect(points.contains(where: {
            $0.x < union.minX || $0.x > union.maxX || $0.y < union.minY || $0.y > union.maxY
        }), "overlap route never escaped the obscuring tile union")
        try expect(DocumentRelationshipOverlayView.route(for: Segment(
            source: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
            target: CGRect(x: 20, y: 0, width: 10, height: 10), emphasized: false)) == nil,
                   "non-finite endpoint geometry must be skipped safely")
    }

    private static func accentDirectedPixelChanges(
        before: NSBitmapImageRep, after: NSBitmapImageRep, pointXRange: ClosedRange<CGFloat>
    ) -> Int {
        guard before.pixelsWide == after.pixelsWide, before.pixelsHigh == after.pixelsHigh,
              let accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) else { return 0 }
        let scale = CGFloat(after.pixelsWide) / max(1, after.size.width)
        let minX = max(0, Int(floor(pointXRange.lowerBound * scale)))
        let maxX = min(after.pixelsWide - 1, Int(ceil(pointXRange.upperBound * scale)))
        guard minX <= maxX else { return 0 }
        func distance(_ color: NSColor, from target: NSColor) -> CGFloat {
            guard let rgb = color.usingColorSpace(.deviceRGB) else { return .greatestFiniteMagnitude }
            return abs(rgb.redComponent - target.redComponent)
                + abs(rgb.greenComponent - target.greenComponent)
                + abs(rgb.blueComponent - target.blueComponent)
        }
        var count = 0
        for x in minX...maxX {
            for y in 0..<after.pixelsHigh {
                guard let old = before.colorAt(x: x, y: y), let new = after.colorAt(x: x, y: y) else { continue }
                let channelDelta = abs(old.redComponent - new.redComponent)
                    + abs(old.greenComponent - new.greenComponent)
                    + abs(old.blueComponent - new.blueComponent)
                if channelDelta > 0.01 && distance(new, from: accent) < distance(old, from: accent) {
                    count += 1
                }
            }
        }
        return count
    }

    private static func checkDocumentRelationshipStabilityAndCost() throws {
        let zone = ZonePlacement(
            zoneId: UUID(), projectId: UUID(), origin: .init(x: 0, y: 0),
            size: .init(width: 900, height: 600), color: "blue", collapsed: false,
            hydrationPolicy: .automatic)
        let agentID = AgentID(rawValue: UUID())
        let agentTile = Tile(id: UUID(), kind: .managedAgent, title: "agent",
                             frame: .init(x: 40, y: 80, width: 220, height: 180),
                             zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: .init())
        let documentTile = Tile(id: UUID(), kind: .file, title: "document",
                                frame: .init(x: 280, y: 100, width: 220, height: 180),
                                zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: .init())
        let canvas = CanvasNSView(
            canvasState: .init(viewport: .init(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: zone, showsZoneChrome: true)
        canvas.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        canvas.install(tileView: DescriptorTileNSView(tile: agentTile), for: agentTile)
        canvas.install(tileView: DescriptorTileNSView(tile: documentTile), for: documentTile)
        let relationshipDate = Date(timeIntervalSinceReferenceDate: 1)
        canvas.setDocumentRelationships(
            [.init(agentId: agentID, documentTileId: documentTile.id,
                   createdAt: relationshipDate, updatedAt: relationshipDate)],
            agentTileIds: [agentID: agentTile.id])
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        try expect(window.makeFirstResponder(canvas), "stability fixture could not focus its canvas")
        let responder = window.firstResponder
        let subviewCount = canvas.worldPlane.subviews.count
        for index in 0..<40 {
            canvas.bringToFront(tileId: index.isMultiple(of: 2) ? agentTile.id : documentTile.id)
        }
        let temporaryZone = ZonePlacement(
            zoneId: UUID(), projectId: nil, origin: .init(x: 620, y: 40),
            size: .init(width: 220, height: 220), color: "purple", collapsed: false,
            hydrationPolicy: .automatic)
        canvas.upsertZoneLayer(.init(
            placement: temporaryZone,
            renderModel: .init(placement: temporaryZone, displayName: "temporary")))
        canvas.removeZoneLayer(zoneId: temporaryZone.zoneId)
        try expect(canvas.worldPlane.subviews.count == subviewCount,
                   "structural reorder cycles leaked or duplicated world-plane views")
        try expect(window.firstResponder === responder,
                   "stacking reconciliation changed the first responder")
        try expect(canvas.qaDocumentRelationshipStackingSnapshot.contractHolds,
                   "background → connector → tile → screen-overlay stacking contract failed")

        let invalidations = canvas.qaDocumentRelationshipDisplayInvalidationCount
        canvas.setDocumentRelationships(
            [.init(agentId: agentID, documentTileId: documentTile.id,
                   createdAt: relationshipDate, updatedAt: relationshipDate)],
            agentTileIds: [agentID: agentTile.id])
        try expect(canvas.qaDocumentRelationshipDisplayInvalidationCount == invalidations,
                   "an unchanged relationship refresh invalidated display")

        // Structural performance witness: one index visit per tile and one link
        // evaluation per durable relationship, including a missing endpoint.
        let largeCanvas = CanvasNSView(
            canvasState: .init(viewport: .init(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
            showsZoneChrome: false)
        largeCanvas.frame = CGRect(x: 0, y: 0, width: 1_200, height: 900)
        let sharedDocument = Tile(id: UUID(), kind: .file, title: "shared",
                                  frame: .init(x: 980, y: 360, width: 120, height: 100),
                                  zPosition: .fromLegacyRank(100), runtimeRef: nil, metadata: .init())
        largeCanvas.install(tileView: DescriptorTileNSView(tile: sharedDocument), for: sharedDocument)
        var ids: [AgentID: UUID] = [:]
        var links: [DocumentAgentLink] = []
        for index in 0..<64 {
            let id = AgentID(rawValue: UUID())
            let tile = Tile(id: UUID(), kind: .managedAgent, title: "agent \(index)",
                            frame: .init(x: Double((index % 8) * 100), y: Double((index / 8) * 100),
                                         width: 80, height: 70),
                            zPosition: .fromLegacyRank(index), runtimeRef: nil, metadata: .init())
            largeCanvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
            ids[id] = tile.id
            links.append(.init(agentId: id, documentTileId: sharedDocument.id,
                               createdAt: relationshipDate, updatedAt: relationshipDate))
        }
        let missingID = AgentID(rawValue: UUID())
        ids[missingID] = UUID()
        links.append(.init(agentId: missingID, documentTileId: sharedDocument.id,
                           createdAt: relationshipDate, updatedAt: relationshipDate))
        largeCanvas.qaResetDocumentRelationshipStats()
        largeCanvas.setDocumentRelationships(links, agentTileIds: ids)
        try expect(largeCanvas.qaDocumentRelationshipStats.tileIndexVisits == 65
                    && largeCanvas.qaDocumentRelationshipStats.linkEvaluations == 65
                    && largeCanvas.qaDocumentRelationshipSegmentCount == 64,
                   "relationship refresh was not O(tiles + links), or failed missing-endpoint filtering: \(largeCanvas.qaDocumentRelationshipStats)")
        // A CAMERA step must now cost nothing at all.
        //
        // This assertion used to demand 65 tile visits and 65 link evaluations per
        // camera step — it pinned the recomputation as the mechanism by which
        // connectors kept up with the camera. They no longer need to: the overlay
        // is a content-sized sibling inside `worldPlane` drawing in world
        // coordinates, so the camera moves it exactly as it moves tiles. Asserting
        // the old counts would now be asserting waste (a 40-step pinch on a canvas
        // with no links at all was paying 960 tile visits and 40 full-viewport
        // frame writes).
        //
        // What the old assertion was FOR is preserved below, as an outcome rather
        // than a mechanism: the connector must still be in the right place after
        // the camera moves.
        largeCanvas.qaResetDocumentRelationshipStats()
        let largeInvalidations = largeCanvas.qaDocumentRelationshipDisplayInvalidationCount
        guard let beforeCameraMove = largeCanvas.qaDocumentRelationshipSegmentRects.first.map({
            largeCanvas.qaSegmentRectInCanvasSpace($0.source)
        }) else {
            try expect(false, "the relationship fixture painted no connector to track")
            return
        }
        let movedViewport = CanvasViewport(
            x: largeCanvas.viewport.x + 137, y: largeCanvas.viewport.y + 91,
            zoom: largeCanvas.viewport.zoom)
        largeCanvas.setViewport(movedViewport)
        try expect(largeCanvas.qaDocumentRelationshipStats.updateCalls == 0
                    && largeCanvas.qaDocumentRelationshipStats.stackingReconciliations == 0
                    && largeCanvas.qaDocumentRelationshipStats.tileIndexVisits == 0
                    && largeCanvas.qaDocumentRelationshipStats.linkEvaluations == 0
                    && largeCanvas.qaDocumentRelationshipStats.frameWrites == 0
                    && largeCanvas.qaDocumentRelationshipDisplayInvalidationCount == largeInvalidations,
                   "a camera step rebuilt or repainted connectors that did not move: \(largeCanvas.qaDocumentRelationshipStats)")

        // The outcome the counts above must not have bought: the connector
        // followed the camera anyway. Its canvas-space position tracks the tiles
        // it joins, and it tracks them for free.
        guard let afterCameraMove = largeCanvas.qaDocumentRelationshipSegmentRects.first.map({
            largeCanvas.qaSegmentRectInCanvasSpace($0.source)
        }) else {
            try expect(false, "the connector vanished when the camera moved")
            return
        }
        let expectedShift = CGPoint(
            x: beforeCameraMove.origin.x - 137 * largeCanvas.viewport.zoom,
            y: beforeCameraMove.origin.y - 91 * largeCanvas.viewport.zoom)
        try expect(abs(afterCameraMove.origin.x - expectedShift.x) < 1.5
                    && abs(afterCameraMove.origin.y - expectedShift.y) < 1.5,
                   "the connector did not follow the camera: expected roughly \(expectedShift), "
                   + "got \(afterCameraMove.origin) — a camera step costs nothing only if the "
                   + "overlay lives in world space, and this is the half that proves it does")

        // And a TILE move — the thing that genuinely changes a connector — must
        // still repaint it. With the camera no longer driving the overlay, this is
        // the invalidation path that has to carry it.
        largeCanvas.qaResetDocumentRelationshipStats()
        largeCanvas.setDocumentRelationships(links, agentTileIds: ids)
        try expect(largeCanvas.qaDocumentRelationshipStats.updateCalls > 0
                    && largeCanvas.qaDocumentRelationshipStats.linkEvaluations == 65,
                   "a real relationship invalidation stopped recomputing after the camera stopped "
                   + "driving the overlay: \(largeCanvas.qaDocumentRelationshipStats)")
    }

    // MARK: - Section 3: an agent's local-file link opens beside the agent

    /// Drives the real production chain — assistant Markdown → semantic link →
    /// `RichInlineTextView.activateLink` → the tile's own render action →
    /// `onOpenLocalFile` → `AgentLocalFileOpener` → `TileSpawner` — inside an
    /// isolated checkout, and proves authored content cannot escape that checkout.
    static func runAgentLocalFileLinkCheck() throws {
        try checkDocumentRelationshipGeometry()
        try checkDocumentRelationshipStabilityAndCost()

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-agent-link-\(UUID().uuidString)", isDirectory: true)
        let checkout = tempRoot.appendingPathComponent("worktree", isDirectory: true)
        let outside = tempRoot.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: checkout.appendingPathComponent("Sources", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: checkout.appendingPathComponent("Docs", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let sourceFile = checkout.appendingPathComponent("Sources/App.swift")
        let sentinel = "let agentLinkSentinel = \"opened-from-a-link\""
        try Data("// line one\n// line two\n\(sentinel)\n// line four\n".utf8).write(to: sourceFile)
        let secretFile = outside.appendingPathComponent("secret.txt")
        try Data("do not open\n".utf8).write(to: secretFile)
        let escapeLink = checkout.appendingPathComponent("escape.txt")
        try fileManager.createSymbolicLink(at: escapeLink, withDestinationURL: secretFile)

        // A single-project workspace: the agent tile and its files share one zone.
        let harness = try makeSingleProjectHarness(root: checkout, tempRoot: tempRoot)
        defer { harness.browserEngine.shutdown() }
        let window = NSWindow(
            contentRect: harness.canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = harness.canvas

        let agentFrame = TileFrame(x: 100, y: 80, width: 460, height: 360)
        let agentTile = Tile(id: UUID(), kind: .managedAgent, title: "agent",
                             frame: agentFrame, zPosition: .fromLegacyRank(1),
                             runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed"))
        let agentView = ManagedAgentTileNSView(tile: agentTile, threadId: "thread-link")
        agentView.frame = NSRect(x: 0, y: 0, width: 460, height: 360)
        harness.canvas.installProjectTile(tileView: agentView, for: agentTile)
        agentView.layoutSubtreeIfNeeded()
        let firstAgentId = AgentID(rawValue: UUID())
        harness.runtime.documentAgentTileIdsProvider = { [agentTileId = agentTile.id] in
            [firstAgentId: agentTileId]
        }

        // Make another zone the canvas's active spawn target. Transcript opens
        // must still be owned and persisted by the source agent's zone.
        let decoyZone = ZonePlacement(
            zoneId: UUID(), projectId: nil,
            origin: ZonePoint(x: 1_600, y: 0), size: ZoneSize(width: 800, height: 700),
            color: "purple", collapsed: false, hydrationPolicy: .automatic,
            name: "Active Decoy", navKey: nil, zPosition: .after(.first)
        )
        harness.canvas.upsertZoneLayer(.init(
            placement: decoyZone,
            renderModel: .init(placement: decoyZone, displayName: decoyZone.name),
            tiles: []
        ))
        harness.canvas.setActiveProjectZone(decoyZone.zoneId)

        var refusals: [String] = []
        var opens: [AgentLocalFileOpener.Result] = []
        let opener = AgentLocalFileOpener(
            openDocument: { request in harness.runtime.openDocument(request) },
            fileTile: { [weak canvas = harness.canvas] tileId in canvas?.tileView(for: tileId) as? FileTileNSView }
        )
        agentView.onOpenLocalFile = { (destination: String) in
            let result = opener.open(
                destination: destination,
                checkoutRoot: checkout,
                sourceTileId: agentTile.id,
                sourceAgentId: firstAgentId,
                projectId: harness.runtime.activeController?.project.id
            )
            opens.append(result)
            if case let .refused(reason) = result { refusals.append(reason) }
        }
        var webTargets: [AgentLinkOpenTarget] = []
        var spawnedBrowserTileIDs: [UUID] = []
        agentView.onOpenWebLink = { url, target in
            webTargets.append(target)
            guard target == .array,
                  let spawner = harness.runtime.activeController?.tileSpawner else { return }
            if case let .spawned(runtime) = spawner.spawnBrowser(
                url: url.absoluteString,
                beside: agentTile.id,
                targetZoneId: harness.zone
            ) {
                spawnedBrowserTileIDs.append(runtime.tileId)
            }
        }

        // Render REAL assistant Markdown through the production ingest path.
        let markdown = """
        Fixed it in [Sources/App.swift](Sources/App.swift:3:5), see also
        [absolute](\(sourceFile.path)), [url form](file://\(sourceFile.path)),
        [docs dir](./Docs), [missing](Sources/Nope.swift), [escape](escape.txt),
        [traversal](../outside/secret.txt), [remote](file://other-host/Sources/App.swift),
        and [the guide](https://example.com/guide).
        """
        agentView.ingest(AgentRuntimeEvent.sessionStateChanged(.running))
        agentView.ingest(AgentRuntimeEvent.turnStarted(threadId: "thread-link", turnId: "turn-1"))
        agentView.ingest(AgentRuntimeEvent.contentDelta(threadId: "thread-link", turnId: "turn-1", streamKind: .assistant, delta: markdown))
        agentView.ingest(AgentRuntimeEvent.turnCompleted(threadId: "thread-link", turnId: "turn-1", outcome: .completed, errorMessage: nil))
        agentView.layoutSubtreeIfNeeded()

        // The links the installed renderer presents, each with how a reader
        // activates it: the list's RichInlineTextViews, or the drawn
        // transcript's laid lines, clicked through its own mouse handling.
        // `target` is an explicit open intent (the context menu's).
        struct RenderedLink {
            let destination: String
            let activate: (AgentLinkOpenTarget?) -> Void
        }
        func renderedLinks() -> [RenderedLink] {
            if let canvas = agentView.qaTranscriptSurface as? AgentTranscriptCanvasView {
                canvas.flushPendingVisualUpdate()
                canvas.layoutSubtreeIfNeeded()
                return canvas.qaDrawnLinks.map { link in
                    RenderedLink(destination: link.destination) { target in
                        if let target {
                            _ = canvas.activateLink(at: link.index, target: target)
                        } else {
                            _ = canvas.qaClickLink(atCharacterIndex: link.index)
                        }
                    }
                }
            }
            var inlineViews: [RichInlineTextView] = []
            func walk(_ view: NSView) {
                if let inline = view as? RichInlineTextView { inlineViews.append(inline) }
                view.subviews.forEach(walk)
            }
            walk(agentView)
            return inlineViews.flatMap { view in
                view.linkRanges.map { link in
                    RenderedLink(destination: link.destination) { target in
                        _ = view.activateLink(at: link.range.location, target: target)
                    }
                }
            }
        }
        let links = renderedLinks()
        try expect(!links.isEmpty, "the assistant message must render semantic links in the tile")

        func activate(_ destination: String) throws {
            let currentLinks = renderedLinks()
            guard let match = currentLinks.first(where: { $0.destination == destination }) else {
                throw Failure(message: "the transcript must contain a link to \(destination); it has \(currentLinks.map(\.destination))")
            }
            match.activate(nil)
        }

        // 1. A relative path with coordinates resolves, opens, and reveals.
        try activate("Sources/App.swift:3:5")
        harness.canvas.layoutSubtreeIfNeeded()
        guard case let .opened(fileTileId, revealedLine) = opens.first else {
            throw Failure(message: "activating a relative local-file link must open a tile; got \(String(describing: opens.first))")
        }
        try expect(revealedLine == 3, "the :3:5 coordinate must survive to the reveal; got \(String(describing: revealedLine))")
        guard let fileView = harness.canvas.tileView(for: fileTileId) as? FileTileNSView else {
            throw Failure(message: "the opened tile must be a real FileTileNSView")
        }
        try expect(fileView.loadedText?.contains(sentinel) == true,
                   "the opened file tile must have loaded the sentinel content")
        let selected = (fileView.textView.string as NSString).substring(with: fileView.textView.selectedRange())
        try expect(selected.contains("agentLinkSentinel"),
                   "the revealed line must be the one the link named; selection was \(selected.debugDescription)")

        // 2. Persisted metadata is the canonical path, with no navigation suffix.
        guard let tile = harness.canvas.tiles(inZone: harness.zone)?.first(where: { $0.id == fileTileId }) else {
            throw Failure(message: "the file tile must belong to the agent's zone layer")
        }
        try expect(tile.metadata.filePath == sourceFile.standardizedFileURL.resolvingSymlinksInPath().path,
                   "persisted metadata must be the canonical path without :line:column; got \(String(describing: tile.metadata.filePath))")
        try expect(tile.metadata.documentLocation?.checkoutRootPath == checkout.resolvingSymlinksInPath().path
                    && tile.metadata.documentLocation?.relativePath == "Sources/App.swift",
                   "the document must persist its source checkout and relative path")
        try expect(tile.zoneId == agentTile.zoneId || tile.zoneId == harness.zone,
                   "the file tile must inherit the responding agent tile's zone")

        // 3. Placement: top-aligned and gap-adjacent to the agent. The spawner's
        // legacy 24pt seed is intentionally compacted by schema-v6 auto layout to
        // the configured/default canvas gap after installation.
        let settledGap = TileGapResolver.defaultGap
        try expect(tile.frame.x == agentFrame.x + agentFrame.width + settledGap,
                   "the file tile must settle exactly \(settledGap)pt right of the agent tile; got x=\(tile.frame.x) against agent \(agentFrame)")
        try expect(tile.frame.y == agentFrame.y,
                   "the file tile must be top-aligned with the agent tile; got y=\(tile.frame.y) against \(agentFrame.y)")
        try expect(harness.focusBroker.activeSurface == .tile(fileTileId),
                   "the newly opened file tile must take focus")

        // 4. Repeat activation reveals, never duplicates.
        let before = harness.canvas.tileIds(inZone: harness.zone).count
        try activate("Sources/App.swift:3:5")
        try expect(harness.canvas.tileIds(inZone: harness.zone).count == before,
                   "activating the same link twice must not create a second tile")
        guard case .revealed = opens[1] else {
            throw Failure(message: "the second activation must reveal the existing tile; got \(opens[1])")
        }
        try expect(harness.runtime.document.documentLinks.count == 1,
                   "repeat opens from one agent must deduplicate the relationship")

        // Web links deliberately have the opposite duplicate policy: every
        // ordinary activation creates a fresh browser beside the authoring
        // agent, in that agent's zone, while explicit system intent creates no
        // canvas state.
        try activate("https://example.com/guide")
        try activate("https://example.com/guide")
        guard let webMatch = renderedLinks().first(where: {
            $0.destination == "https://example.com/guide"
        }) else { throw Failure(message: "the transcript lost its https link") }
        webMatch.activate(.systemBrowser)
        try expect(webTargets == [.array, .array, .systemBrowser],
                   "web link activation must preserve Array vs system intent; got \(webTargets)")
        try expect(Set(spawnedBrowserTileIDs).count == 2,
                   "two ordinary clicks must create two distinct browser tiles")
        for browserTileID in spawnedBrowserTileIDs {
            try expect(harness.canvas.tileIds(inZone: harness.zone).contains(browserTileID),
                       "a transcript browser must belong to the source agent's zone")
            try expect(harness.canvas.tileView(for: browserTileID) is BrowserTileNSView,
                       "a transcript web link must install a real BrowserTileNSView")
        }

        // A second agent reveals the same canonical document and contributes a
        // second persistent relationship (and therefore a second connector).
        let secondAgentId = AgentID(rawValue: UUID())
        let secondTile = Tile(
            id: UUID(), kind: .managedAgent, title: "second agent",
            frame: TileFrame(x: 100, y: 520, width: 460, height: 360),
            zPosition: .fromLegacyRank(2), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        )
        harness.canvas.installProjectTile(
            tileView: ManagedAgentTileNSView(tile: secondTile, threadId: "thread-link-2"),
            for: secondTile, targetZoneId: harness.zone
        )
        harness.runtime.documentAgentTileIdsProvider = {
            [firstAgentId: agentTile.id, secondAgentId: secondTile.id]
        }
        let secondResult = opener.open(
            destination: "Sources/App.swift:3:5", checkoutRoot: checkout,
            sourceTileId: secondTile.id, sourceAgentId: secondAgentId,
            projectId: harness.runtime.activeController?.project.id
        )
        guard case let .revealed(secondTileDocumentId, _) = secondResult,
              secondTileDocumentId == fileTileId else {
            throw Failure(message: "a second agent must reveal the canonical document; got \(secondResult)")
        }
        try expect(harness.runtime.document.documentLinks.count == 2,
                   "a second agent must add a relationship to the same document")
        try expect(harness.canvas.qaDocumentRelationshipSegmentCount == 2,
                   "both visible agent relationships must render connector geometry")
        try expect(harness.canvas.qaDocumentRelationshipStackingSnapshot.contractHolds,
                   "the relationship overlay must sit above zone chrome and below every tile")

        // Render the actual transcript-created relationship through the real
        // window hierarchy. Comparing link-off/link-on pixels in the exposed gap
        // makes the shipped 0.5.7 stacking defect red: its zone chrome covers the
        // overlay, so that corridor is byte-identical.
        let artifactStamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let artifactDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs/\(artifactStamp)/document-relationships", isDirectory: true)
        try fileManager.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let persistedLinks = harness.runtime.document.documentLinks
        let persistedAgentTiles = harness.runtime.documentAgentTileIdsProvider?() ?? [:]
        guard let firstRoute = harness.canvas.qaDocumentRelationshipRoutes.first else {
            throw Failure(message: "the transcript-created relationship has no drawable route")
        }
        // The corridor is compared against pixels of the CANVAS, so it has to be
        // in the canvas's coordinates. A route's points are in the overlay's own
        // space, and those two used to be the same space only because the overlay
        // was viewport-sized and camera-driven. It is now a content-sized sibling
        // inside `worldPlane`, so the conversion is no longer the identity — and
        // reading the raw route x's looks for the connector in the wrong column
        // and finds background.
        let routePoints = firstRoute.points.map { point in
            harness.canvas.qaSegmentRectInCanvasSpace(CGRect(origin: point, size: .zero)).origin
        }
        let corridorX: ClosedRange<CGFloat>
        if let minimum = routePoints.map(\.x).min(), let maximum = routePoints.map(\.x).max() {
            corridorX = minimum...maximum
        } else {
            throw Failure(message: "the transcript-created relationship route has no points")
        }
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: appearanceName)
            NSApp.appearance = appearance
            window.appearance = appearance
            harness.canvas.setDocumentRelationships([], agentTileIds: persistedAgentTiles)
            let before = try UIProbe.bitmap(
                of: harness.canvas, id: "document-relationship.\(appearanceName.rawValue).before", scale: 1)
            harness.canvas.setDocumentRelationships(persistedLinks, agentTileIds: persistedAgentTiles)
            let after = try UIProbe.bitmap(
                of: harness.canvas, id: "document-relationship.\(appearanceName.rawValue).after", scale: 1)
            let coloredPixels = accentDirectedPixelChanges(before: before, after: after, pointXRange: corridorX)
            try expect(coloredPixels >= 2,
                       "\(appearanceName.rawValue) rendered no connector-colored pixels in the visible endpoint corridor")
            guard let png = after.representation(using: .png, properties: [:]) else {
                throw Failure(message: "could not encode \(appearanceName.rawValue) relationship render")
            }
            try png.write(to: artifactDirectory.appendingPathComponent("\(appearanceName.rawValue).png"))
        }
        print("Document relationship renders: \(artifactDirectory.path)")

        // 5. The absolute and file:// spellings of the same file reveal that tile too.
        try activate(sourceFile.path)
        try activate("file://\(sourceFile.path)")
        try expect(harness.canvas.allWorkspaceTiles().filter { $0.kind == .file }.count == 1,
                   "absolute and file:// spellings of an open file must reveal, not duplicate")
        for index in 2...3 {
            guard case let .revealed(tileId, _) = opens[index], tileId == fileTileId else {
                throw Failure(message: "activation \(index) must resolve to the same canonical tile; got \(opens[index])")
            }
        }

        // 6. Everything outside the checkout creates nothing. Two layers refuse:
        //    policy stops a remote `file://` authority before it can even become an
        //    action, and the resolver stops what policy legitimately let through.
        let tilesBeforeRefusals = harness.canvas.tileIds(inZone: harness.zone)
        let refusedByResolver = ["./Docs", "Sources/Nope.swift", "escape.txt", "../outside/secret.txt"]
        for destination in refusedByResolver + ["file://other-host/Sources/App.swift"] {
            try activate(destination)
        }
        try expect(harness.canvas.tileIds(inZone: harness.zone) == tilesBeforeRefusals,
                   "a directory, a missing file, a symlink escape, a traversal, and a remote file host must create no tile")
        try expect(refusals.count == refusedByResolver.count,
                   "each candidate destination outside the checkout must be refused with a reason; got \(refusals)")
        try expect(refusals.contains(where: { $0.contains("Docs") && $0.contains("notARegularFile") }),
                   "a directory must be refused as a non-file; got \(refusals)")
        try expect(refusals.filter { $0.contains("outsideCheckout") }.count == 2,
                   "the symlink escape and the traversal must both be refused as outside the checkout; got \(refusals)")
        try expect(AgentLinkPolicy.disposition(for: "file://other-host/Sources/App.swift") == .displayOnly,
                   "a remote file authority must never classify as a local-file candidate")

        // 7. HTTPS stays a URL action and never becomes a file action.
        let opensBeforeHTTPS = opens.count
        try activate("https://example.com/guide")
        try expect(opens.count == opensBeforeHTTPS,
                   "an https link must never reach the local-file opener")
        try expect(AgentLinkPolicy.disposition(for: "https://example.com/guide") == .openExternally,
                   "https must stay externally dispositioned")

        // Persist the exact linked endpoint tiles, reload the schema-v6 document
        // twice, then reconstruct a fresh runtime/canvas as a relaunch would.
        // This runs after every activation/refusal assertion so the deliberate
        // second runtime cannot perturb the live transcript fixture under test.
        guard let persistedZoneTiles = harness.canvas.tiles(inZone: harness.zone) else {
            throw Failure(message: "the project zone disappeared before relaunch persistence")
        }
        try harness.projectStore.saveCanvas(.init(
            viewport: .init(x: 0, y: 0, zoom: 1), tiles: persistedZoneTiles,
            groups: [], lastActiveTileId: fileTileId))
        let firstReload = try harness.workspaceStore.load()
        try expect(firstReload.schemaVersion == WorkspaceDocument.currentSchemaVersion
                       && firstReload.documentLinks.count == 2,
                   "first workspace relaunch lost or duplicated relationships")
        try harness.workspaceStore.save(firstReload)
        let secondReload = try harness.workspaceStore.load()
        try expect(secondReload.documentLinks == firstReload.documentLinks,
                   "second workspace relaunch changed relationship identity or order")
        let relaunched = try makeSingleProjectHarness(
            root: checkout, tempRoot: tempRoot, initializeStore: false)
        defer { relaunched.browserEngine.shutdown() }
        relaunched.runtime.documentAgentTileIdsProvider = {
            [firstAgentId: agentTile.id, secondAgentId: secondTile.id]
        }
        relaunched.canvas.layoutSubtreeIfNeeded()
        try expect(relaunched.canvas.qaDocumentRelationshipSegmentCount == 2,
                   "relaunch did not restore both visible relationship connectors")
        try expect(relaunched.canvas.qaDocumentRelationshipStackingSnapshot.contractHolds,
                   "relaunch did not restore the stacking contract")

        // ==================================================================
        // T9 (`.plans/48`) — the two cases nothing covered.
        //
        // Everything above takes the ANCHORED branch, because the agent tile is in
        // `tiles(inZone: harness.zone)`. The uncovered combination is a target zone
        // with NO INSTALLED LAYER: `tiles(inZone:)` returns nil, `siblings` silently
        // fell back to the ACTIVE zone's tiles, the anchor was "not found", and both
        // fallbacks were wrong — the frame came from `makeProjectTilePlacement` with
        // no `targetZoneId` (zone-local to the ACTIVE zone, then installed into the
        // target's), and `zoneId` came out nil. One real store held exactly that: a
        // file tile at world (1246,-851) belonging to no zone at all.
        // ==================================================================
        let layerlessZoneId = UUID(uuidString: "00000000-0000-0000-0000-0000000F2909")!
        var docWithLayerlessZone = harness.runtime.document
        docWithLayerlessZone.zones.append(ZonePlacement(
            zoneId: layerlessZoneId,
            projectId: docWithLayerlessZone.zones.first(where: { $0.zoneId == harness.zone })?.projectId,
            origin: ZonePoint(x: 3_000, y: 1_500), size: ZoneSize(width: 1_200, height: 900),
            color: "orange", collapsed: false, hydrationPolicy: .automatic,
            name: "Layerless", navKey: nil, zPosition: .after(.first)))
        harness.runtime.replaceDocument(docWithLayerlessZone, for: harness.runtime.workspaceId)

        // An agent tile in that zone, installed FLAT — exactly the boot scene, where
        // no layer exists and `zoneId(containing:)` answers from the flat model.
        let layerlessAgentFrame = TileFrame(x: 3_100, y: 1_600, width: 460, height: 360)
        var layerlessAgent = Tile(
            id: UUID(), kind: .managedAgent, title: "layerless agent",
            frame: layerlessAgentFrame, zPosition: .fromLegacyRank(5),
            runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed"))
        layerlessAgent.zoneId = layerlessZoneId
        harness.canvas.install(
            tileView: ManagedAgentTileNSView(tile: layerlessAgent, threadId: "thread-layerless"),
            for: layerlessAgent)
        harness.canvas.layoutSubtreeIfNeeded()
        try expect(harness.canvas.installedZonePlacement(for: layerlessZoneId) == nil,
                   "the layerless zone must genuinely have no installed layer, or this case "
                   + "proves nothing")

        let docsFile = checkout.appendingPathComponent("Docs/notes.md")
        try Data("# Notes\n".utf8).write(to: docsFile)
        let layerlessOutcome = harness.runtime.openDocument(.init(
            location: DocumentLocation(path: docsFile.path, scope: .standalone),
            placement: .beside(tileId: layerlessAgent.id),
            sourceAgentId: firstAgentId,
            sourceTileId: layerlessAgent.id))
        harness.canvas.layoutSubtreeIfNeeded()
        guard case let .opened(layerlessFileId) = layerlessOutcome else {
            throw Failure(message: "opening beside a layerless-zone agent must succeed; got \(layerlessOutcome)")
        }
        guard let layerlessFile = harness.canvas.tileRecord(for: layerlessFileId) else {
            throw Failure(message: "the layerless-zone file tile must be installed")
        }
        try expect(layerlessFile.zoneId != nil,
                   "layerless zone: the file tile must NEVER be left with a nil zoneId — a bare "
                   + "tile renders outside every zone and no zone gesture can reach it. This is "
                   + "the (1246,-851) tile from the field.")
        try expect(layerlessFile.zoneId == layerlessZoneId,
                   "layerless zone: the file must inherit the OPENING AGENT's zone; got "
                   + "\(String(describing: layerlessFile.zoneId))")
        // World geometry, not the stamp: the frame/install split leaves the stamp
        // correct while displacing the tile by the difference of two zone origins.
        try expect(abs(layerlessFile.frame.y - layerlessAgentFrame.y) < 1,
                   "layerless zone: the file must be top-aligned with its agent in WORLD "
                   + "coordinates; got y=\(layerlessFile.frame.y) against \(layerlessAgentFrame.y)")
        try expect(layerlessFile.frame.x > layerlessAgentFrame.x,
                   "layerless zone: the file must sit to the RIGHT of its agent, not displaced "
                   + "toward the active zone's origin; got x=\(layerlessFile.frame.x) against "
                   + "agent x=\(layerlessAgentFrame.x)")

        // The zoneId fallback is defensive, and needs its own case: an anchor that
        // cannot be resolved at all, with a target zone that IS known. Production
        // reaches this through `openDocument`'s repoint, which derives
        // `sourceZoneId` from the project rather than from the source tile, so the
        // two can disagree. Before the fix the tile came out with `zoneId: nil`.
        if let spawner = harness.runtime.activeController?.tileSpawner {
            let orphanFile = checkout.appendingPathComponent("Docs/orphan.md")
            try Data("# Orphan\n".utf8).write(to: orphanFile)
            let outcome = spawner.spawnFile(
                location: DocumentLocation(path: orphanFile.path, scope: .standalone),
                title: nil,
                at: nil,
                beside: UUID(),                      // never installed
                targetZoneId: layerlessZoneId)
            guard case let .spawned(orphanId) = outcome,
                  let orphan = harness.canvas.tileRecord(for: orphanId) else {
                throw Failure(message: "spawning with an unresolvable anchor must still open a tile; got \(outcome)")
            }
            try expect(orphan.zoneId == layerlessZoneId,
                       "unresolvable anchor: the tile must fall back to the TARGET zone rather "
                       + "than being left bare; got \(String(describing: orphan.zoneId))")
        }

        // An explicit drop point beats the anchor. `openDocument`'s `.at` demux sets
        // BOTH, and preferring the anchor threw away where the user actually dropped.
        let droppedFile = checkout.appendingPathComponent("Docs/dropped.md")
        try Data("# Dropped\n".utf8).write(to: droppedFile)
        let dropPoint = CGPoint(x: 3_400, y: 2_050)
        let dropOutcome = harness.runtime.openDocument(.init(
            location: DocumentLocation(path: droppedFile.path, scope: .standalone),
            placement: .at(dropPoint),
            sourceAgentId: firstAgentId,
            sourceTileId: layerlessAgent.id))
        harness.canvas.layoutSubtreeIfNeeded()
        guard case let .opened(droppedId) = dropOutcome,
              let dropped = harness.canvas.tileRecord(for: droppedId) else {
            throw Failure(message: "dropping a file must open a tile; got \(dropOutcome)")
        }
        let droppedCentre = CGPoint(x: dropped.frame.x + dropped.frame.width / 2,
                                    y: dropped.frame.y + dropped.frame.height / 2)
        try expect(abs(droppedCentre.x - dropPoint.x) < 1 && abs(droppedCentre.y - dropPoint.y) < 1,
                   "drop point: an explicit .at(point) must beat the anchor. Expected the tile "
                   + "centred on \(dropPoint); got \(droppedCentre).")

    }

    private struct SingleProjectHarness {
        let runtime: WorkspaceRuntime
        let canvas: CanvasNSView
        let focusBroker: FocusBroker
        let browserEngine: BrowserEngineContext
        let projectStore: ProjectStore
        let workspaceStore: WorkspaceStore
        let zone: UUID
    }

    private static func makeSingleProjectHarness(
        root: URL, tempRoot: URL, initializeStore: Bool = true
    ) throws -> SingleProjectHarness {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-0000000F2001")!
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000F2102")!
        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-0000000F2203")!

        let project = Project(id: projectId, name: "Worktree", rootPath: root.path, createdAt: now, updatedAt: now,
                              defaultLaunchProfileId: "shell", editorPreference: .auto,
                              settings: ProjectSettings(restorePolicy: .restoreDescriptors,
                                                        browserStoragePolicy: .perProject,
                                                        terminalClosePolicy: .askWhenRunning))
        let store = ProjectStore(projectRoot: root)
        if initializeStore {
            try store.saveProject(project)
            try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        }

        let initialDocument = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [ZonePlacement(zoneId: zoneId, projectId: projectId, origin: ZonePoint(x: 0, y: 0),
                                  size: ZoneSize(width: 2_000, height: 1_400), color: "blue",
                                  collapsed: false, hydrationPolicy: .automatic)],
            zoneZOrder: [zoneId],
            lastActiveZoneId: zoneId
        )
        let workspaceStore = WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport)
        if initializeStore { try workspaceStore.save(initialDocument) }
        let document = initializeStore ? initialDocument : try workspaceStore.load()

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceId
        appRegistry.projects = [ProjectEntry(id: projectId, name: "Worktree", rootPath: root.path,
                                             workspaceId: workspaceId, lastOpenedAt: now,
                                             pinned: false, missing: false)]
        appRegistry.workspaces = [WorkspaceEntry(id: workspaceId, name: "Worktree", projectIds: [projectId],
                                                 createdAt: now, updatedAt: now)]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        if initializeStore { try registryStore.save(appRegistry) }

        let focusBroker = FocusBroker()
        let browserEngine = BrowserEngineContext()
        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { _ in
            ZoneRuntimeController(projectRoot: root, projectStore: store, project: project)
        })
        let runtime = WorkspaceRuntime(workspaceId: workspaceId, document: document, registry: zoneRegistry,
                                       focusBroker: focusBroker, registryStore: registryStore,
                                       ghostty: nil, browserEngine: browserEngine)
        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: true
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 1_800, height: 1_200)
        try runtime.install(into: canvas, appRegistry: appRegistry)
        canvas.layoutSubtreeIfNeeded()
        return SingleProjectHarness(runtime: runtime, canvas: canvas, focusBroker: focusBroker,
                                    browserEngine: browserEngine, projectStore: store,
                                    workspaceStore: workspaceStore, zone: zoneId)
    }

    // MARK: - Section 2: Markdown preview / editing

    static func runMarkdownPreviewCheck() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-file-markdown-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let markdownURL = tempRoot.appendingPathComponent("README.md")
        try Data(sentinelMarkdown.utf8).write(to: markdownURL)
        let upperURL = tempRoot.appendingPathComponent("NOTES.MARKDOWN")
        try Data("# Upper\n".utf8).write(to: upperURL)
        let decoyURL = tempRoot.appendingPathComponent("notes.md.txt")
        try Data("# Not markdown\n".utf8).write(to: decoyURL)
        let swiftURL = tempRoot.appendingPathComponent("Long.swift")
        let longLine = String(repeating: "let wide = \"padding\" // ", count: 40)
        let longSource = (0..<400).map { "\($0) \(longLine)" }.joined(separator: "\n")
        try Data(longSource.utf8).write(to: swiftURL)

        // Core classification.
        try expect(FilePreview.presentation(forPath: markdownURL.path) == .markdown, "README.md must classify as markdown")
        try expect(FilePreview.presentation(forPath: upperURL.path) == .markdown, "NOTES.MARKDOWN must classify as markdown (case-insensitive)")
        try expect(FilePreview.presentation(forPath: decoyURL.path) == .sourceText, "notes.md.txt must NOT classify as markdown")
        try expect(FilePreview.presentation(forPath: swiftURL.path) == .sourceText, "a .swift file must classify as source")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = host

        func makeTile(path: String) -> FileTileNSView {
            let tile = Tile(id: UUID(), kind: .file, title: URL(fileURLWithPath: path).lastPathComponent,
                            frame: TileFrame(x: 0, y: 0, width: 520, height: 420),
                            zPosition: .fromLegacyRank(1), runtimeRef: nil,
                            metadata: TileMetadata(filePath: path))
            let view = FileTileNSView(tile: tile)
            view.frame = NSRect(x: 10, y: 10, width: 520, height: 420)
            host.addSubview(view)
            view.layoutSubtreeIfNeeded()
            return view
        }

        // Markdown defaults to a rendered Preview.
        let markdownTile = makeTile(path: markdownURL.path)
        try expect(markdownTile.presentation == .markdown, "a .md tile must resolve markdown presentation")
        try expect(markdownTile.mode == .preview, "a markdown tile must default to Preview")
        guard let document = markdownTile.qaMarkdownDocument else {
            throw Failure(message: "a markdown tile must install the native Markdown document view")
        }
        markdownTile.layoutSubtreeIfNeeded()
        document.layoutSubtreeIfNeeded()

        let rendered = document.qaVisibleText()
        for fragment in ["Sentinel Report", "active", "inline code", "link", "first item", "second item",
                         "quoted line", "fenced-code-sentinel"] {
            try expect(rendered.contains(fragment),
                       "rendered Markdown must lay out \(fragment.debugDescription); rendered text was \(rendered.debugDescription)")
        }
        // Unsupported constructs degrade visibly rather than vanishing.
        try expect(rendered.contains("1") && rendered.contains("2"),
                   "an unsupported table must still show its content as readable text")
        try expect(!rendered.contains("# Sentinel Report"),
                   "Preview must render the heading, not echo its Markdown source")
        try expect(document.qaBlockViews.allSatisfy { $0.frame.height > 0 },
                   "every rendered block must have real laid-out height")
        try expect(document.qaBlockViews.count >= 6,
                   "the sentinel document must produce a block per semantic element; got \(document.qaBlockViews.count)")

        // Links are classified but a file document activates nothing.
        let inlineViews = document.qaInlineTextViews()
        let linkRanges = inlineViews.flatMap(\.linkRanges)
        try expect(linkRanges.contains(where: { $0.destination == "https://example.com/docs" && $0.disposition == .openExternally }),
                   "the rendered document must expose its link with the shared policy disposition")
        try expect(inlineViews.contains(where: { $0.isSelectable && !$0.isEditable }),
                   "rendered Markdown must stay natively selectable and read-only")

        // Appearance: tokens repaint on a theme change.
        func inlineColor(_ view: FileMarkdownDocumentView) -> NSColor? {
            view.qaInlineTextViews().first?.textStorage?
                .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        var editorArguments = originalArguments
        editorArguments[EditorPreferences.appearanceKey] = EditorAppearance.light.rawValue
        UserDefaults.standard.setVolatileDomain(editorArguments, forName: UserDefaults.argumentDomain)
        markdownTile.applyTokens()
        let lightColor = inlineColor(document)?.usingColorSpace(.sRGB)
        editorArguments[EditorPreferences.appearanceKey] = EditorAppearance.dark.rawValue
        UserDefaults.standard.setVolatileDomain(editorArguments, forName: UserDefaults.argumentDomain)
        markdownTile.applyTokens()
        let darkColor = inlineColor(document)?.usingColorSpace(.sRGB)
        try expect(lightColor != nil && darkColor != nil && lightColor != darkColor,
                   "the Markdown document must repaint through appearance tokens (light \(String(describing: lightColor)) vs dark \(String(describing: darkColor)))")

        // A real mouse event reaches the segmented control through the draggable
        // title bar and Edit shows the exact Markdown in the same tile.
        let identityBefore = markdownTile.tile.id
        let loadedBefore = markdownTile.loadedText
        guard let modeControl = markdownTile.qaModeControl else {
            throw Failure(message: "a markdown tile must offer a Preview/Edit control")
        }
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        markdownTile.layoutSubtreeIfNeeded()
        let editPoint = modeControl.convert(
            NSPoint(x: modeControl.bounds.width * 0.75, y: modeControl.bounds.midY), to: nil
        )
        func modeMouse(_ type: NSEvent.EventType, number: Int) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type, location: editPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: number, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else { throw Failure(message: "could not create Preview/Edit mouse event") }
            return event
        }
        NSApplication.shared.postEvent(try modeMouse(.leftMouseUp, number: 2), atStart: false)
        modeControl.mouseDown(with: try modeMouse(.leftMouseDown, number: 1))
        markdownTile.layoutSubtreeIfNeeded()
        try expect(markdownTile.mode == .edit, "a real click on the mode control must switch the tile to Edit")
        try expect(markdownTile.textView.string == sentinelMarkdown,
                   "Edit must show the exact decoded Markdown")
        try expect(markdownTile.qaCodeEditorVisible,
                   "Edit must mount a visible CodeMirror surface")
        try expect(markdownTile.tile.id == identityBefore, "switching modes must not change tile identity")
        try expect(markdownTile.loadedText == loadedBefore, "switching modes must reuse the one loaded snapshot")

        // Editing is a draft: Preview reflects it immediately, but only an
        // explicit save mutates disk.
        let draft = sentinelMarkdown + "\n\n## Unsaved Draft\n"
        markdownTile.textView.string = draft
        markdownTile.textView.didChangeText()
        try expect(markdownTile.isDirty, "editing Markdown must mark the tile dirty")
        let diskBeforeSave = try String(contentsOf: markdownURL, encoding: .utf8)
        try expect(diskBeforeSave == sentinelMarkdown,
                   "editing and mode changes must not save implicitly")
        markdownTile.setMode(.preview)
        markdownTile.layoutSubtreeIfNeeded()
        try expect(markdownTile.mode == .preview && markdownTile.qaMarkdownDocument === document,
                   "switching back to Preview must reuse the same document view")
        try expect(document.qaVisibleText().contains("Unsaved Draft"),
                   "Preview must render the current unsaved draft")
        try expect(markdownTile.save(), "explicit Markdown save must succeed")
        let diskAfterSave = try String(contentsOf: markdownURL, encoding: .utf8)
        try expect(!markdownTile.isDirty && diskAfterSave == draft,
                   "explicit save must atomically write the draft and clear dirty state")

        // Clean external edits reload; dirty ones become a conflict and cannot
        // be overwritten without an explicit overwrite choice.
        let external = draft + "\nexternal clean edit\n"
        try external.write(to: markdownURL, atomically: true, encoding: .utf8)
        markdownTile.refreshFromDisk()
        try expect(markdownTile.loadedText == external && !markdownTile.isDirty,
                   "a clean tile must reload external changes")
        markdownTile.setMode(.edit)
        markdownTile.textView.string = external + "\nlocal conflict edit\n"
        markdownTile.textView.didChangeText()
        let secondExternal = external + "\nsecond external edit\n"
        try secondExternal.write(to: markdownURL, atomically: true, encoding: .utf8)
        markdownTile.refreshFromDisk()
        try expect(markdownTile.hasExternalConflict && markdownTile.isDirty,
                   "an external edit must preserve and mark a dirty local draft")
        try expect(!markdownTile.save(), "a conflicted draft must refuse an ordinary save")
        try expect(markdownTile.save(overwriteExternalChanges: true) && !markdownTile.isDirty,
                   "an explicit overwrite must save the local draft and clear the conflict")

        // A missing file continues to be polled: its missing signature differs
        // from the last loaded signature. Repeated failures must retain the
        // actual action view, and restoration must recover even when the very
        // same inode and bytes return (so the original signature is unchanged).
        let missingURL = tempRoot.appendingPathComponent("TEMPORARILY-MISSING.md")
        let heldURL = tempRoot.appendingPathComponent("TEMPORARILY-MISSING.held")
        let missingText = "# Temporarily missing\n\nKeep this draft.\n"
        try missingText.write(to: missingURL, atomically: true, encoding: .utf8)
        let missingTile = makeTile(path: missingURL.path)
        let editorBody = missingTile.qaActiveBody
        guard let unchangedDocument = missingTile.qaMarkdownDocument else {
            throw Failure(message: "fixture must render its Markdown document")
        }
        let unchangedBlocks = unchangedDocument.qaBlockViews
        let unchangedThemeCount = unchangedDocument.qaThemeApplicationCount
        let unchangedRenderCount = unchangedDocument.qaMarkdownApplyCount
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                      ofItemAtPath: missingURL.path)
        missingTile.refreshFromDisk()
        try expect(missingTile.qaMarkdownDocument === unchangedDocument
                   && unchangedDocument.qaBlockViews.count == unchangedBlocks.count
                   && zip(unchangedDocument.qaBlockViews, unchangedBlocks).allSatisfy { $0.0 === $0.1 }
                   && unchangedDocument.qaThemeApplicationCount == unchangedThemeCount
                   && unchangedDocument.qaMarkdownApplyCount == unchangedRenderCount,
                   "metadata-only changes with unchanged bytes must retain rendered blocks")
        try fileManager.moveItem(at: missingURL, to: heldURL)
        missingTile.refreshFromDisk()
        guard let firstMissingBody = missingTile.qaActiveBody else {
            throw Failure(message: "missing file must present an action body")
        }
        try expect(firstMissingBody !== editorBody, "missing file must replace the editor body with actions")
        let missingThemeCount = unchangedDocument.qaThemeApplicationCount
        let missingRenderCount = unchangedDocument.qaMarkdownApplyCount
        var replacements = 0
        for _ in 0..<8 {
            missingTile.refreshFromDisk()
            if missingTile.qaActiveBody !== firstMissingBody { replacements += 1 }
        }
        print("file missing refresh: \(replacements) action-body replacements, " +
              "\(unchangedDocument.qaThemeApplicationCount - missingThemeCount) theme applications and " +
              "\(unchangedDocument.qaMarkdownApplyCount - missingRenderCount) full renders across 8 repeated polls")
        try expect(replacements == 0 && unchangedDocument.qaThemeApplicationCount == missingThemeCount
                   && unchangedDocument.qaMarkdownApplyCount == missingRenderCount,
                   "unchanged missing-file polls must retain their action body and avoid Markdown re-rendering")
        try expect(missingTile.qaExternalChangeMonitoringActive,
                   "the mounted missing-file fixture must keep its production monitor")
        // Let pending file-operation events settle, then count real monitor
        // callbacks over more than two of the old one-second polling periods.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let priorPolls = missingTile.qaExternalPollCount
        let priorWatcherEvents = FileContentObservation.shared.qaEventCount
        RunLoop.main.run(until: Date().addingTimeInterval(2.3))
        let idleCallbacks = missingTile.qaExternalPollCount - priorPolls
        let idleWatcherEvents = FileContentObservation.shared.qaEventCount - priorWatcherEvents
        print("file tile idle callbacks over 2.3 seconds: \(idleCallbacks); shared watcher events: \(idleWatcherEvents)")
        try expect(idleCallbacks == 0 && idleWatcherEvents == 0,
                   "unchanged mounted files must not wake their tile or shared watcher")
        try expect(missingTile.qaActiveBody === firstMissingBody
                   && unchangedDocument.qaThemeApplicationCount == missingThemeCount
                   && unchangedDocument.qaMarkdownApplyCount == missingRenderCount,
                   "idle observation must retain the same missing action body")

        // A different failure must update the visible explanation, and a
        // subsequent missing result must be retryable rather than cached away.
        try fileManager.createDirectory(at: missingURL, withIntermediateDirectories: false)
        missingTile.refreshFromDisk()
        try expect(missingTile.qaActiveBody !== firstMissingBody,
                   "a new unavailable reason must update the missing-file actions")
        let directoryFailureBody = missingTile.qaActiveBody
        try fileManager.removeItem(at: missingURL)
        missingTile.refreshFromDisk()
        try expect(missingTile.qaActiveBody !== directoryFailureBody,
                   "the missing reason must be shown again after a retry")
        let lastMissingBody = missingTile.qaActiveBody
        let park = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
        host.addSubview(park)
        try expect(missingTile.parkBodyFarOffscreen(park: park)
                   && missingTile.qaParkedBody === lastMissingBody,
                   "the missing action body must be parkable before recovery")
        try fileManager.moveItem(at: heldURL, to: missingURL)
        let restorationDeadline = Date().addingTimeInterval(3)
        while missingTile.qaActiveBody !== editorBody, Date() < restorationDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(missingTile.qaActiveBody === editorBody && missingTile.loadedText == missingText
                   && missingTile.surfaceResidency == .native && missingTile.qaParkedBody == nil,
                   "restoring the original file must promote and reattach its unchanged editor")

        // A clean file restored with new bytes becomes the new editor contents,
        // and the missing-file save-failure badge must clear.
        try fileManager.removeItem(at: missingURL)
        missingTile.refreshFromDisk()
        let cleanChangedText = missingText + "external clean change\n"
        try cleanChangedText.write(to: missingURL, atomically: true, encoding: .utf8)
        missingTile.refreshFromDisk()
        try expect(missingTile.qaActiveBody === editorBody && missingTile.loadedText == cleanChangedText && !missingTile.isDirty
                   && !missingTile.hasExternalConflict && missingTile.qaDirtyIndicatorText.isEmpty,
                   "a clean changed restoration must reload and clear the missing-file failure badge")

        // A dirty draft must be preserved and made visible when a different
        // on-disk file returns. The replacement is a conflict, not a reload.
        missingTile.setMode(.edit)
        let missingProtectedDraft = cleanChangedText + "local unsaved work\n"
        missingTile.textView.string = missingProtectedDraft
        missingTile.textView.didChangeText()
        try fileManager.removeItem(at: missingURL)
        missingTile.refreshFromDisk()
        let secondMissingBody = missingTile.qaActiveBody
        try (cleanChangedText + "external change\n").write(to: missingURL, atomically: true, encoding: .utf8)
        missingTile.refreshFromDisk()
        try expect(missingTile.qaActiveBody === editorBody && missingTile.qaActiveBody !== secondMissingBody
                   && missingTile.hasExternalConflict
                   && missingTile.isDirty && missingTile.qaDraftText == missingProtectedDraft,
                   "a changed restored file must reveal and preserve the conflicted draft")
        try expect(missingTile.qaDirtyIndicatorAccessibilityLabel == "File changed on disk; unsaved changes",
                   "restored conflict must announce the conflict instead of the prior missing-file failure")

        // A trash notification carries a real restore target. Continued polling
        // must not discard that target or disable the existing restore button.
        let trashSource = tempRoot.appendingPathComponent("TEMPORARY-TRASH.md")
        let trashDestination = tempRoot.appendingPathComponent("TEMPORARY-TRASH.held")
        try missingText.write(to: trashSource, atomically: true, encoding: .utf8)
        let trashTile = makeTile(path: trashSource.path)
        let trashEditorBody = trashTile.qaActiveBody
        try fileManager.moveItem(at: trashSource, to: trashDestination)
        NotificationCenter.default.post(name: .arrayProjectFileTrashed, object: nil,
                                        userInfo: ["source": trashSource.path, "trash": trashDestination.path])
        guard let trashBody = trashTile.qaActiveBody else {
            throw Failure(message: "Trash must present restore actions")
        }
        func restoreButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "Restore" { return button }
            return view.subviews.lazy.compactMap { restoreButton(in: $0) }.first
        }
        guard let restore = restoreButton(in: trashBody) else {
            throw Failure(message: "Trash must provide a restore button")
        }
        try expect(restore.isEnabled, "Trash restore must start enabled")
        trashTile.refreshFromDisk()
        try expect(trashTile.qaActiveBody === trashBody && restore.isEnabled,
                   "missing-file polling must retain the enabled Trash restore action")
        restore.performClick(nil)
        try expect(fileManager.fileExists(atPath: trashSource.path) && trashTile.qaActiveBody === trashEditorBody,
                   "the retained Trash action must restore the file and editor")

        // The control exists only for Markdown.
        try expect(markdownTile.qaModeControl != nil, "a markdown tile must offer a Preview/Edit control")
        let swiftTile = makeTile(path: swiftURL.path)
        try expect(swiftTile.presentation == .sourceText, "a .swift tile must stay source-only")
        try expect(swiftTile.qaModeControl == nil, "a non-Markdown tile must have no mode control")
        try expect(swiftTile.qaMarkdownDocument == nil, "a non-Markdown tile must not build a Markdown document")
        try expect(swiftTile.qaSourceLanguage == .swift, "a .swift tile must carry Swift presentation grammar")
        try expect(swiftTile.qaHasLineNumbers, "a source tile must show a line-number gutter")
        try expect(swiftTile.qaSyntaxForegroundCount >= 2,
                   "a Swift source tile must render more than one syntax foreground")
        try expect(swiftTile.qaCodeEditorVisible,
                   "a source tile must mount a visible CodeMirror surface")
        let agentEdit = "let agentChangedThis = true\n"
        try agentEdit.write(to: swiftURL, atomically: true, encoding: .utf8)
        swiftTile.refreshFromDisk()
        try expect(swiftTile.textView.string == agentEdit && swiftTile.qaSyntaxForegroundCount >= 2,
                   "a clean source tile must live-refresh an external agent edit with syntax styling")

        // Real editors and agents commonly replace a file atomically. Timestamp-only
        // polling can miss a same-size replacement when the timestamp is preserved
        // or collides with the previous write, even though the inode changed.
        let priorDate = (try FileManager.default.attributesOfItem(atPath: swiftURL.path)[.modificationDate]) as? Date
        let sameSizeEdit = "let agentChangedThit = true\n"
        try expect(sameSizeEdit.utf8.count == agentEdit.utf8.count,
                   "fixture: replacement must preserve byte count")
        try sameSizeEdit.write(to: swiftURL, atomically: true, encoding: .utf8)
        if let priorDate {
            try FileManager.default.setAttributes([.modificationDate: priorDate], ofItemAtPath: swiftURL.path)
        }
        swiftTile.refreshFromDisk()
        try expect(swiftTile.textView.string == sameSizeEdit,
                   "a same-size atomic replacement with a preserved timestamp must still refresh")

        // Drive the mounted production observer instead of calling refresh directly.
        try expect(swiftTile.qaExternalChangeMonitoringActive,
                   "a mounted file tile must actively monitor external edits")
        let timerEdit = "let agentChangedThix = true\n"
        try timerEdit.write(to: swiftURL, atomically: true, encoding: .utf8)
        if let priorDate {
            try FileManager.default.setAttributes([.modificationDate: priorDate], ofItemAtPath: swiftURL.path)
        }
        let timerDeadline = Date().addingTimeInterval(2.5)
        while swiftTile.textView.string != timerEdit, Date() < timerDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(swiftTile.textView.string == timerEdit,
                   "the mounted tile's production monitor must display an atomic agent edit without manual reload")
        // In-place writes do not necessarily change the parent directory.
        let inPlaceEdit = "let editedInPlace = true\n"
        let handle = try FileHandle(forWritingTo: swiftURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(inPlaceEdit.utf8))
        try handle.close()
        let inPlaceDeadline = Date().addingTimeInterval(3)
        while swiftTile.textView.string != inPlaceEdit, Date() < inPlaceDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(swiftTile.textView.string == inPlaceEdit,
                   "the mounted monitor must reload an in-place edit")
        // A transition suppresses refresh; an editor-process termination must
        // reconcile an event consumed while the transition was pending.
        swiftTile.qaSetDocumentTransitionPending(true)
        let priorTransitionEvents = swiftTile.qaExternalPollCount
        let afterTransition = "let afterEditorTermination = true\n"
        try afterTransition.write(to: swiftURL, atomically: true, encoding: .utf8)
        let transitionDeadline = Date().addingTimeInterval(3)
        while swiftTile.qaExternalPollCount == priorTransitionEvents, Date() < transitionDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(swiftTile.qaExternalPollCount > priorTransitionEvents && swiftTile.textView.string == inPlaceEdit,
                   "the external event must arrive while the editor transition suppresses reload")
        swiftTile.qaSimulateEditorProcessTermination()
        try expect(swiftTile.textView.string == afterTransition,
                   "editor termination must reconcile the suppressed external edit")

        // A link's own metadata does not change when its target is edited or
        // replaced in another directory; both changes must reload the tile.
        let targetDirectory = tempRoot.appendingPathComponent("watch-target", isDirectory: true)
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let targetURL = targetDirectory.appendingPathComponent("target.txt")
        let linkURL = tempRoot.appendingPathComponent("watch-link.txt")
        let intermediateLink = targetDirectory.appendingPathComponent("intermediate.txt")
        try "link initial".write(to: targetURL, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(atPath: intermediateLink.path, withDestinationPath: targetURL.path)
        try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: intermediateLink.path)
        let linkedTile = makeTile(path: linkURL.path)
        let linkHandle = try FileHandle(forWritingTo: targetURL)
        try linkHandle.truncate(atOffset: 0)
        try linkHandle.write(contentsOf: Data("link in place".utf8))
        try linkHandle.close()
        let linkWriteDeadline = Date().addingTimeInterval(3)
        while linkedTile.loadedText != "link in place", Date() < linkWriteDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(linkedTile.loadedText == "link in place", "linked target writes must reload")
        try "link replaced".write(to: targetURL, atomically: true, encoding: .utf8)
        let linkReplaceDeadline = Date().addingTimeInterval(3)
        while linkedTile.loadedText != "link replaced", Date() < linkReplaceDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(linkedTile.loadedText == "link replaced", "linked target replacement must reload")
        try fileManager.removeItem(at: targetURL)
        let linkMissingDeadline = Date().addingTimeInterval(3)
        let linkedBody = linkedTile.qaActiveBody
        while linkedTile.qaActiveBody === linkedBody, Date() < linkMissingDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(linkedTile.qaActiveBody !== linkedBody, "a linked target removal must be observed")
        try "link restored".write(to: targetURL, atomically: true, encoding: .utf8)
        let linkRestoreDeadline = Date().addingTimeInterval(3)
        while linkedTile.loadedText != "link restored", Date() < linkRestoreDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(linkedTile.loadedText == "link restored", "a linked target recreation must reload")

        // Moving an ancestor (not just the immediate parent) invalidates the
        // document path and restoring that ancestor must resume monitoring.
        let outer = tempRoot.appendingPathComponent("watch-outer", isDirectory: true)
        let heldOuter = tempRoot.appendingPathComponent("watch-outer-held", isDirectory: true)
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        let ancestorFile = inner.appendingPathComponent("file.txt")
        try fileManager.createDirectory(at: inner, withIntermediateDirectories: true)
        try "ancestor original".write(to: ancestorFile, atomically: true, encoding: .utf8)
        let ancestorTile = makeTile(path: ancestorFile.path)
        let ancestorBody = ancestorTile.qaActiveBody
        try fileManager.moveItem(at: outer, to: heldOuter)
        let ancestorMissingDeadline = Date().addingTimeInterval(3)
        while ancestorTile.qaActiveBody === ancestorBody, Date() < ancestorMissingDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(ancestorTile.qaActiveBody !== ancestorBody, "moving an ancestor must mark the file missing")
        try fileManager.moveItem(at: heldOuter, to: outer)
        let ancestorRestoreDeadline = Date().addingTimeInterval(3)
        while ancestorTile.qaActiveBody !== ancestorBody, Date() < ancestorRestoreDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(ancestorTile.qaActiveBody === ancestorBody, "restoring an ancestor must restore its editor")
        try "ancestor updated".write(to: ancestorFile, atomically: true, encoding: .utf8)
        let ancestorUpdateDeadline = Date().addingTimeInterval(3)
        while ancestorTile.loadedText != "ancestor updated", Date() < ancestorUpdateDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(ancestorTile.loadedText == "ancestor updated", "an ancestor restore must rearm file updates")

        // Two hosts share observation; replacing a removed parent must rearm
        // the path, and removing one host must not detach the other.
        let nestedDirectory = tempRoot.appendingPathComponent("watch-nested", isDirectory: true)
        let nestedFile = nestedDirectory.appendingPathComponent("shared.txt")
        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try "first".write(to: nestedFile, atomically: true, encoding: .utf8)
        let firstShared = makeTile(path: nestedFile.path)
        let secondShared = makeTile(path: nestedFile.path)
        let firstBody = firstShared.qaActiveBody
        let secondBody = secondShared.qaActiveBody
        try fileManager.removeItem(at: nestedDirectory)
        let missingDeadline = Date().addingTimeInterval(3)
        while (firstShared.qaActiveBody === firstBody || secondShared.qaActiveBody === secondBody),
              Date() < missingDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(firstShared.qaActiveBody !== firstBody && secondShared.qaActiveBody !== secondBody,
                   "both shared observers must see their parent disappear")
        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try "restored".write(to: nestedFile, atomically: true, encoding: .utf8)
        let sharedDeadline = Date().addingTimeInterval(3)
        while (firstShared.loadedText != "restored" || secondShared.loadedText != "restored"),
              Date() < sharedDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(firstShared.loadedText == "restored" && secondShared.loadedText == "restored",
                   "both shared observers must reload after their parent returns")
        firstShared.removeFromSuperview()
        try "remaining".write(to: nestedFile, atomically: true, encoding: .utf8)
        let remainingDeadline = Date().addingTimeInterval(3)
        while secondShared.loadedText != "remaining", Date() < remainingDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(secondShared.loadedText == "remaining",
                   "removing one observer must leave the other subscribed")
        try longSource.write(to: swiftURL, atomically: true, encoding: .utf8)

        let decoyTile = makeTile(path: decoyURL.path)
        try expect(decoyTile.qaModeControl == nil, "a filename merely containing .md must not get Markdown treatment")

        // Reveal: a coordinate refers to the text, so a Markdown tile shows Source
        // and selects the named line.
        let revealTile = makeTile(path: markdownURL.path)
        revealTile.reveal(line: 6, column: 3)
        revealTile.layoutSubtreeIfNeeded()
        try expect(revealTile.mode == .edit, "revealing a line in a Markdown tile must switch to Edit")
        let lines = sentinelMarkdown.components(separatedBy: "\n")
        let expectedStart = lines.prefix(5).reduce(0) { $0 + ($1 as NSString).length + 1 }
        try expect(revealTile.textView.selectedRange().location == expectedStart + 2,
                   "reveal(line:6, column:3) must select from that coordinate; got \(revealTile.textView.selectedRange())")
        try expect((revealTile.textView.string as NSString)
                    .substring(with: revealTile.textView.selectedRange()) == "first item",
                   "the revealed selection must run from the column to the end of the named line")

        // In a file long enough to scroll, revealing actually moves the viewport.
        let longRevealTile = makeTile(path: swiftURL.path)
        longRevealTile.layoutSubtreeIfNeeded()
        try expect(longRevealTile.qaFirstVisibleSourceLine() == 1, "a freshly opened source tile starts at line 1")
        longRevealTile.reveal(line: 300)
        longRevealTile.layoutSubtreeIfNeeded()
        let revealedLine = longRevealTile.qaFirstVisibleSourceLine()
        try expect(revealedLine != nil && revealedLine! > 100,
                   "revealing line 300 must scroll the source there; first visible line was \(String(describing: revealedLine))")

        // Restore: the persisted `.file` metadata alone recreates a Preview tile.
        let restored = makeTile(path: markdownURL.path)
        try expect(restored.mode == .preview && restored.qaMarkdownDocument != nil,
                   "restoring a .file tile from persisted metadata must come back in Preview")

        let splitMetadata = TileMetadata(
            filePath: markdownURL.path,
            markdownDocumentMode: .split
        )
        let splitTileModel = Tile(
            id: UUID(), kind: .file, title: "README.md",
            frame: TileFrame(x: 0, y: 0, width: 620, height: 420),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: splitMetadata
        )
        let splitTile = FileTileNSView(tile: splitTileModel)
        try expect(splitTile.mode == .split && splitTile.qaMarkdownDocument != nil,
                   "persisted Split mode must restore the shared source/preview surface")
        splitTile.reveal(line: 6, column: 3)
        try expect(splitTile.mode == .split,
                   "a source reveal must keep an already-visible Split surface active")

        // Native authoring commands operate on the canonical source and remain
        // undoable NSTextView edits.
        splitTile.setMode(.edit)
        splitTile.textView.string = "format me"
        splitTile.textView.setSelectedRange(NSRange(location: 0, length: 6))
        MarkdownEditingCommands.apply(.bold, in: splitTile.textView)
        try expect(splitTile.textView.string == "**format** me",
                   "Bold must wrap the selected Markdown source")
        splitTile.textView.string = "- item"
        splitTile.textView.setSelectedRange(NSRange(location: 6, length: 0))
        try expect(MarkdownEditingCommands.handleCommand(
            #selector(NSResponder.insertNewline(_:)), in: splitTile.textView
        ), "Return in a list item must be handled by Markdown continuation")
        try expect(splitTile.textView.string == "- item\n- ",
                   "Return must continue the active Markdown list marker")
        splitTile.textView.string = "- "
        splitTile.textView.setSelectedRange(NSRange(location: 2, length: 0))
        try expect(MarkdownEditingCommands.handleCommand(
            #selector(NSResponder.insertNewline(_:)), in: splitTile.textView
        ), "Return in an empty list item must be handled")
        try expect(splitTile.textView.string.isEmpty,
                   "Return in an empty list item must exit the list")

        // A dirty checkout-scoped Markdown tile writes an atomic recovery draft.
        // Rehydrating the same tile restores it, preserves a concurrent disk edit
        // as a conflict, and explicit overwrite clears the recovery file.
        let recoveryURL = tempRoot.appendingPathComponent("RECOVERY.md")
        let recoveryBase = "# Recovery base\n"
        try recoveryBase.write(to: recoveryURL, atomically: true, encoding: .utf8)
        let recoveryTileID = UUID()
        let recoveryLocation = DocumentLocation(
            path: recoveryURL.path,
            scope: .checkout(projectId: UUID(), rootPath: tempRoot.path, relativePath: "RECOVERY.md")
        )
        let recoveryModel = Tile(
            id: recoveryTileID, kind: .file, title: "RECOVERY.md",
            frame: TileFrame(x: 0, y: 0, width: 620, height: 420),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(filePath: recoveryURL.path, documentLocation: recoveryLocation)
        )
        let recoveryWriter = FileTileNSView(tile: recoveryModel)
        recoveryWriter.setMode(.edit)
        let protectedDraft = recoveryBase + "local unsaved work\n"
        recoveryWriter.textView.string = protectedDraft
        recoveryWriter.textView.didChangeText()
        recoveryWriter.qaFlushRecoveryDraft()
        guard let protectedURL = recoveryWriter.qaRecoveryURL else {
            throw Failure(message: "checkout Markdown tile must resolve a recovery URL")
        }
        try expect(fileManager.fileExists(atPath: protectedURL.path),
                   "flushing a dirty tile must durably create its recovery record")

        let concurrentDisk = recoveryBase + "agent changed disk\n"
        try concurrentDisk.write(to: recoveryURL, atomically: true, encoding: .utf8)
        let recoveryReader = FileTileNSView(tile: recoveryModel)
        try expect(recoveryReader.textView.string == protectedDraft && recoveryReader.isDirty,
                   "rehydration must restore the complete unsaved draft")
        try expect(recoveryReader.hasExternalConflict,
                   "rehydration must report a conflict when disk changed after the draft base")
        try expect(recoveryReader.save(overwriteExternalChanges: true),
                   "explicit overwrite must save a recovered conflicting draft")
        try expect(!fileManager.fileExists(atPath: protectedURL.path),
                   "saving a recovered draft must remove its recovery record")
    }

    // MARK: - Changes-card file previews

    /// The strip of file previews in the Changes card: each kind renders a
    /// thumbnail off the main thread, a click opens the file in a tile beside
    /// the agent without overlapping anything, a second click reveals that tile
    /// instead of making another, and hover animates the fade away.
    static func runFilePreviewOpenCheck() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-file-preview-\(UUID().uuidString)", isDirectory: true)
        let checkout = tempRoot.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: checkout.appendingPathComponent("Sources", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        // One file of every previewed kind, created by the agent.
        let png = checkout.appendingPathComponent("shot.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemIndigo.setFill(); NSRect(x: 0, y: 0, width: 320, height: 200).fill()
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        let md = checkout.appendingPathComponent("report.md")
        try Data("# A report with a title long enough that it has to wrap onto a second line of the preview\n\nFirst paragraph of the report.\n".utf8).write(to: md)
        let html = checkout.appendingPathComponent("page.html")
        try Data("<html><body style='background:#123'><h1 style='color:white'>Hello</h1></body></html>".utf8).write(to: html)
        let svg = checkout.appendingPathComponent("badge.svg")
        try Data("<svg xmlns='http://www.w3.org/2000/svg' width='160' height='100'><rect width='160' height='100' fill='#c33'/><circle cx='80' cy='50' r='30' fill='white'/></svg>".utf8).write(to: svg)
        let swift = checkout.appendingPathComponent("Sources/Writer.swift")
        try Data("import Foundation\n\nstruct Writer {\n    func write() {}\n}\n".utf8).write(to: swift)
        let pdf = checkout.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdfContext = CGContext(pdf as CFURL, mediaBox: &box, nil) else { throw Failure(message: "no pdf context") }
        pdfContext.beginPDFPage(nil); pdfContext.setFillColor(CGColor(gray: 0.2, alpha: 1))
        pdfContext.fill(CGRect(x: 50, y: 600, width: 300, height: 100)); pdfContext.endPDFPage(); pdfContext.closePDF()

        // Kinds: an edit to the markdown or source stays a plain row.
        try expect(FilePreviewKind(url: md, action: .edit) == nil, "an edited markdown file must not get a preview")
        try expect(FilePreviewKind(url: swift, action: .edit) == nil, "an edited source file must not get a preview")
        try expect(FilePreviewKind(url: md, action: .add) == .document, "a created markdown file must get a preview")
        try expect(FilePreviewKind(url: png, action: .edit) == .image, "an image earns a preview however it was touched")

        // 1. A thumbnail renders for each kind, off the main thread, and is cached
        //    by path and modification time.
        let store = FilePreviewStore.shared
        store.resetForChecks()
        try expect(FilePreviewKind(url: svg, action: .write) == .web, "a created svg must get a preview, rendered as the page tile renders it")
        let kinds: [(URL, FilePreviewKind)] = [(png, .image), (md, .document), (html, .web), (svg, .web), (swift, .code), (pdf, .pdf)]
        for (url, kind) in kinds {
            var ready = false
            let immediate = store.preview(url, kind: kind, dark: true) { ready = true }
            try expect(immediate == nil, "\(kind): the first request must not block the main thread for a picture")
            let deadline = Date().addingTimeInterval(15)
            while !ready && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            guard let made = store.cached(url, kind: kind, dark: true) else {
                throw Failure(message: "\(kind): no thumbnail was produced for \(url.lastPathComponent)")
            }
            try expect(made.image.height > 0 && made.blurred.height == made.image.height && made.aspect > 0.2,
                       "\(kind): the thumbnail and its blurred copy must be real pictures")
        }
        let generated = store.generationCount
        _ = store.preview(png, kind: .image, dark: true) {}
        try expect(store.generationCount == generated, "an unchanged file must be served from the cache")
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: png.path)
        _ = store.preview(png, kind: .image, dark: true) {}
        try expect(store.generationCount == generated + 1, "a file with a new modification time must be regenerated")
        _ = store.preview(md, kind: .document, dark: false) {}
        try expect(store.generationCount == generated + 2, "drawn text must be cached per appearance")

        // 2. Each transcript renderer's strip, in an agent's card, opens files beside
        //    the agent. The drawn transcript is the default and runs first; the row
        //    list is the fallback and must behave the same.
        final class Flag { var done = false }
        func finishAsync(_ work: @escaping @MainActor () async throws -> Void) throws {
            let flag = Flag(); var failure: Error?
            Task { @MainActor in
                do { try await work() } catch { failure = error }
                flag.done = true
            }
            let limit = Date().addingTimeInterval(30)
            while !flag.done && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            if let failure { throw failure }
            try expect(flag.done, "the transcript did not finish loading")
        }
        let motionLabel = "hover"
        func exercise(drawn: Bool) throws {
            let renderer = drawn ? "drawn transcript" : "row list"
            let harness = try makeSingleProjectHarness(root: checkout, tempRoot: tempRoot)
            defer { harness.browserEngine.shutdown() }
            let window = NSWindow(contentRect: harness.canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = harness.canvas
            let agentTile = Tile(id: UUID(), kind: .managedAgent, title: "agent",
                                 frame: TileFrame(x: 100, y: 80, width: 460, height: 360), zPosition: .fromLegacyRank(1),
                                 runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed"))
            let agentView = ManagedAgentTileNSView(tile: agentTile, threadId: "thread-preview")
            agentView.frame = NSRect(x: 0, y: 0, width: 460, height: 360)
            harness.canvas.installProjectTile(tileView: agentView, for: agentTile)
            let agentId = AgentID(rawValue: UUID())
            harness.runtime.documentAgentTileIdsProvider = { [agentTileId = agentTile.id] in [agentId: agentTileId] }
            let opener = AgentLocalFileOpener(
                openDocument: { request in harness.runtime.openDocument(request) },
                fileTile: { [weak canvas = harness.canvas] tileId in canvas?.tileView(for: tileId) as? FileTileNSView })
            var results: [AgentLocalFileOpener.Result] = []
            let perform: (AgentRenderAction) -> Void = { action in
                guard case let .openLocalFile(_, destination) = action else { return }
                results.append(opener.open(destination: destination, checkoutRoot: checkout, sourceTileId: agentTile.id,
                                           sourceAgentId: agentId, projectId: harness.runtime.activeController?.project.id))
            }
            let files = [md, png, html, swift, pdf].map {
                AgentDiffFileSummary(displayName: $0.lastPathComponent, action: .add, fileURL: $0)
            }

            // The surface under test, behind four verbs.
            var thumbCount = { 0 }
            var placeholders = { 0 }
            var click: (Int) -> Void = { _ in }
            var cover: (Int) -> CGFloat = { _ in 1 }
            var hover: (Int?) -> Void = { _ in }
            var overlapFree = { true }
            var drawnDebug = { "" }
            let stripWindow: NSWindow
            if drawn {
                let store = AgentToolDetailStore()
                let canvas = AgentTranscriptCanvasView(toolDetailStore: store)
                canvas.frame = NSRect(x: 0, y: 0, width: 1_100, height: 420)
                stripWindow = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                stripWindow.contentView = canvas
                stripWindow.orderFrontOffscreenForChecks()
                try canvas.updateRenderContext(AgentRenderContext(actions: AgentRenderActions(perform), tokens: .transcript, appearance: .dark))
                try finishAsync {
                    let thread = "strip-thread"
                    var projection = AgentTranscriptProjection(threadId: thread)
                    try projection.appendUserPrompt(id: AgentNodeID(rawValue: "strip-user")!, text: "Write the files.")
                    var entries = projection.document.entries
                    let scope = AgentToolDetailScope(agentID: "strip-agent", threadID: thread, turnID: "turn-0", provider: "runtime")!
                    let itemID = AgentToolDetailID(stringLiteral: "write-0")
                    let key = AgentToolDetailKey(scope: scope, providerItemID: itemID)
                    _ = await store.recordStart(AgentToolDetailStart(
                        identity: key, toolName: "write", affectedFiles: files.compactMap(\.fileURL),
                        fileChanges: files.map { .init(action: .add, path: $0.displayName, addedLines: 24, removedLines: 0) }))
                    _ = await store.recordEnd(AgentToolDetailEnd(identity: key, status: .completed))
                    let block = AgentBlock(id: AgentNodeID(rawValue: "strip-diff")!, revision: 1, kind: .diff,
                                           payload: .diff(AgentDiffPayload(text: "", summary: "")))
                    let entry = AgentEntry(id: AgentNodeID(rawValue: "strip-diff-entry")!, revision: 1, role: .assistant,
                                           provenance: .providerItem(provider: "runtime", itemID: itemID.rawValue), blocks: [block])
                    _ = canvas.bindToolDetailIdentity(key, to: entry.id)
                    entries.append(entry)
                    let document = AgentDocument(version: 1, entries: entries)
                    try canvas.enqueue(document: document, patch: AgentDocumentPatch(
                        fromVersion: 0, toVersion: 1, inserted: document.entries.flatMap(\.blocks).map(\.id)), final: true)
                    await canvas.qaAdoptStoreRecords()
                    await canvas.qaWaitForToolDetailRefresh()
                }
                let settle = Date().addingTimeInterval(20)
                repeat {
                    canvas.flushPendingVisualUpdate(); canvas.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                } while (canvas.qaFileThumbs.count < 5 || canvas.qaFileThumbs.contains { !$0.hasPicture }) && Date() < settle
                thumbCount = { canvas.qaFileThumbs.count }
                drawnDebug = { "blocks \(canvas.qaPlacedBlockIDs.map(\.rawValue)) text '\(canvas.qaLaidOutText.prefix(200))' err \(String(describing: canvas.qaRenderingErrorDescription)) frame \(canvas.frame)" }
                placeholders = { canvas.qaFileThumbs.filter { !$0.hasPicture }.count }
                func event(_ type: NSEvent.EventType, at index: Int) -> NSEvent {
                    let center = canvas.qaFileThumbs[index].center
                    return NSEvent.mouseEvent(with: type, location: canvas.convert(center, to: nil), modifierFlags: [], timestamp: 0,
                                              windowNumber: stripWindow.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: 1)!
                }
                click = { index in
                    canvas.mouseDown(with: event(.leftMouseDown, at: index))
                    canvas.mouseUp(with: event(.leftMouseUp, at: index))
                }
                cover = { canvas.qaFileThumbs[$0].cover }
                hover = { index in
                    if let index { canvas.mouseMoved(with: event(.mouseMoved, at: index)) }
                    else { canvas.mouseExited(with: NSEvent.enterExitEvent(
                        with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: stripWindow.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!) }
                }
                overlapFree = {
                    let centers = canvas.qaFileThumbs.map(\.center.x)
                    return zip(centers, centers.dropFirst()).allSatisfy { $0 + 48 < $1 - 48 }
                }
            } else {
                let strip = AgentFileStripView(frame: NSRect(x: 0, y: 0, width: 1_100, height: 120))
                let host = NSView(frame: strip.frame); host.addSubview(strip)
                stripWindow = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                stripWindow.contentView = host
                strip.apply(files: files, tokens: .transcript, theme: .dark, zoom: .default, perform: perform,
                            blockID: AgentNodeID(rawValue: "preview-block")!)
                let settle = Date().addingTimeInterval(15)
                while strip.qaPlaceholderCount > 0 && Date() < settle { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                strip.layoutSubtreeIfNeeded()
                let frames = strip.qaThumbFrames
                thumbCount = { strip.qaThumbCount }
                placeholders = { strip.qaPlaceholderCount }
                click = { index in
                    let windowPoint = strip.convert(NSPoint(x: frames[index].midX, y: frames[index].midY), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: 0,
                                                       windowNumber: stripWindow.windowNumber, context: nil, eventNumber: 0,
                                                       clickCount: 1, pressure: 1)!
                        if type == .leftMouseDown { strip.mouseDown(with: event) } else { strip.mouseUp(with: event) }
                    }
                }
                cover = { CGFloat(strip.qaFadeOpacity(at: $0)) }
                hover = { strip.setHovered($0) }
                overlapFree = { zip(frames, frames.dropFirst()).allSatisfy { $0.maxX < $1.minX && $0.width >= 96 } }
            }
            try expect(thumbCount() == 5 && placeholders() == 0, "\(renderer): the strip must show a thumbnail for each previewed file (\(thumbCount()) thumbs, \(placeholders()) placeholders; \(drawnDebug()))")
            try expect(overlapFree(), "\(renderer): thumbnails must sit in one row without overlapping")

            func fileTiles() -> [Tile] { harness.canvas.allTilesInWorldFrames().filter { $0.kind == .file } }
            func assertBesideAndClear(_ label: String) throws {
                let tiles = harness.canvas.allTilesInWorldFrames()
                guard let agent = tiles.first(where: { $0.id == agentTile.id }) else { throw Failure(message: "\(renderer) \(label): the agent tile vanished") }
                for file in tiles where file.kind == .file {
                    let beside = file.frame.x >= agent.frame.x + agent.frame.width - 0.5
                        || file.frame.y >= agent.frame.y + agent.frame.height - 0.5
                    try expect(beside, "\(renderer) \(label): \(file.title) must open beside the agent, got \(file.frame) next to \(agent.frame)")
                    try expect(file.zoneId == agent.zoneId, "\(renderer) \(label): \(file.title) must open in the agent's own zone")
                }
                for (i, a) in tiles.enumerated() {
                    for b in tiles[(i + 1)...] {
                        let overlap = a.frame.x < b.frame.x + b.frame.width && b.frame.x < a.frame.x + a.frame.width
                            && a.frame.y < b.frame.y + b.frame.height && b.frame.y < a.frame.y + a.frame.height
                        try expect(!overlap, "\(renderer) \(label): \(a.title) and \(b.title) overlap")
                    }
                }
            }

            // Every kind opens IN Array, as a tile beside the agent, and nothing is ever
            // handed to another app (Preview, a browser, an editor).
            ExternalOpenAudit.count = 0
            click(0)
            try expect(fileTiles().count == 1, "\(renderer): clicking a thumbnail must open exactly one file tile, got \(fileTiles().count)")
            guard case .opened(let firstTile, _) = results.last else { throw Failure(message: "\(renderer) first click: expected .opened, got \(String(describing: results.last))") }
            try assertBesideAndClear("first click")
            for index in 1..<5 { click(index) }
            let all = harness.canvas.allTilesInWorldFrames()
            try expect(all.filter { $0.kind == .file }.count == 4 && all.filter { $0.kind == .browser }.count == 1,
                       "\(renderer): md, png, swift and pdf open as file tiles and html as a browser tile; got \(all.map(\.kind))")
            try expect(!results.contains { if case .refused = $0 { return true } else { return false } }, "\(renderer): no kind may be refused: \(results)")
            for tile in all where tile.kind == .file {
                guard let view = harness.canvas.tileView(for: tile.id) as? FileTileNSView else { throw Failure(message: "\(tile.title) has no file tile view") }
                try expect(view.qaRendersInArray, "\(renderer): \(tile.title) must render in Array, not offer to open elsewhere")
            }
            if let browser = all.first(where: { $0.kind == .browser }) {
                try expect(browser.metadata.url == html.absoluteString || browser.metadata.url == URL(fileURLWithPath: html.path).standardizedFileURL.resolvingSymlinksInPath().absoluteString,
                           "\(renderer): the html opens in a browser tile on its own file URL, got \(String(describing: browser.metadata.url))")
            }
            try expect(ExternalOpenAudit.count == 0, "\(renderer): a thumbnail click must never hand a file to another app (\(ExternalOpenAudit.count) external opens)")
            try assertBesideAndClear("all five")
            let before = harness.canvas.allTilesInWorldFrames().count
            click(0)
            guard case .revealed(let again, _) = results.last, again == firstTile else {
                throw Failure(message: "\(renderer): clicking an open file again must reveal its tile, got \(String(describing: results.last))")
            }
            try expect(harness.canvas.allTilesInWorldFrames().count == before, "\(renderer): revealing an open file must not make a second tile")
            click(2)
            guard case .revealed = results.last else { throw Failure(message: "\(renderer): clicking an open page again must reveal its browser tile, got \(String(describing: results.last))") }
            try expect(harness.canvas.allTilesInWorldFrames().count == before, "\(renderer): revealing an open page must not make a second tile")
            try expect(ExternalOpenAudit.count == 0, "\(renderer): revealing must not open externally either")

            // 3. Hover removes the fade and blur from the hovered thumbnail only, over
            //    the transcript's own emphasis duration.
            try expect(cover(0) == 1 && cover(1) == 1, "\(renderer): a resting thumbnail is faded and blurred")
            AgentTranscriptMotion.qaWithMotion(enabled: true) {
                hover(1)
                if drawn {
                    try? expect(cover(1) > 0 && cover(1) < 1 || cover(1) == 1, "\(renderer): hover starts an animation, not a jump")
                    RunLoop.main.run(until: Date().addingTimeInterval(AgentTranscriptMotion.emphasis + 0.25))
                }
            }
            try expect(cover(1) == 0, "\(renderer): the hovered thumbnail shows in full (\(motionLabel))")
            try expect(cover(0) == 1, "\(renderer): an unhovered thumbnail stays faded")
            AgentTranscriptMotion.qaWithMotion(enabled: true) {
                hover(nil)
                if drawn { RunLoop.main.run(until: Date().addingTimeInterval(AgentTranscriptMotion.emphasis + 0.25)) }
            }
            try expect(cover(1) == 1, "\(renderer): leaving restores the fade")
            print("file preview strip (\(renderer)): thumbnails for 5 kinds, click opens beside the agent, second click reveals, hover clears the fade")
        }
        // 4. One turn that writes three files draws ONE Changes card with ONE strip,
        //    not a card and a "Write" line per file. An edit of an existing file in
        //    the same turn keeps its own card.
        func groupedTurn() throws {
            let store = AgentToolDetailStore()
            let canvas = AgentTranscriptCanvasView(toolDetailStore: store)
            canvas.frame = NSRect(x: 0, y: 0, width: 1_100, height: 640)
            let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = canvas
            window.orderFrontOffscreenForChecks()
            try canvas.updateRenderContext(AgentRenderContext(actions: AgentRenderActions({ _ in }), tokens: .transcript, appearance: .dark))
            try finishAsync {
                let thread = "group-thread"
                var projection = AgentTranscriptProjection(threadId: thread)
                try projection.appendUserPrompt(id: AgentNodeID(rawValue: "group-user")!, text: "Make three files and tidy the writer.")
                var entries = projection.document.entries
                let scope = AgentToolDetailScope(agentID: "group-agent", threadID: thread, turnID: "turn-0", provider: "runtime")!
                let operations: [(String, URL, AgentToolDetailObservation.FileAction)] = [
                    ("shot", png, .write), ("report", md, .write), ("badge", svg, .write), ("writer", swift, .edit)]
                for (name, url, action) in operations {
                    let itemID = AgentToolDetailID(stringLiteral: "op-\(name)")
                    let key = AgentToolDetailKey(scope: scope, providerItemID: itemID)
                    _ = await store.recordStart(AgentToolDetailStart(
                        identity: key, toolName: action == .edit ? "edit" : "write", affectedFiles: [url],
                        fileChanges: [.init(action: action, path: url.lastPathComponent, addedLines: 4, removedLines: action == .edit ? 1 : nil)]))
                    _ = await store.recordEnd(AgentToolDetailEnd(identity: key, status: .completed))
                    let block = AgentBlock(id: AgentNodeID(rawValue: "group-diff-\(name)")!, revision: 1, kind: .diff,
                                           payload: .diff(AgentDiffPayload(text: "", summary: action == .edit ? "Edit" : "Write")))
                    let entry = AgentEntry(id: AgentNodeID(rawValue: "group-entry-\(name)")!, revision: 1, role: .assistant,
                                           provenance: .providerItem(provider: "runtime", itemID: itemID.rawValue), blocks: [block])
                    _ = canvas.bindToolDetailIdentity(key, to: entry.id)
                    entries.append(entry)
                }
                let document = AgentDocument(version: 1, entries: entries)
                try canvas.enqueue(document: document, patch: AgentDocumentPatch(
                    fromVersion: 0, toVersion: 1, inserted: document.entries.flatMap(\.blocks).map(\.id)), final: true)
                await canvas.qaAdoptStoreRecords()
                await canvas.qaWaitForToolDetailRefresh()
            }
            let settle = Date().addingTimeInterval(20)
            repeat {
                canvas.flushPendingVisualUpdate(); canvas.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            } while (canvas.qaFileThumbs.count < 3 || canvas.qaFileThumbs.contains { !$0.hasPicture }) && Date() < settle
            let cards = canvas.qaChangesCards
            let created = cards.filter { $0.files.allSatisfy { $0.action == .write } }
            try expect(created.count == 1, "three Writes in one turn must make one Changes card, got \(created.count) (of \(cards.count) cards)")
            try expect(created.first?.files.map(\.displayName).count == 3, "the one card must hold all three files, got \(created.first?.files.map(\.displayName) ?? [])")
            try expect(created.first?.summary == nil, "the grouped card must not carry a per-operation \"Write\" line")
            try expect(cards.count == 2 && cards.contains { $0.files.contains { $0.action == .edit } },
                       "an edit to an existing file keeps its own card, got \(cards.count) cards")
            let thumbs = canvas.qaFileThumbs
            try expect(thumbs.count == 3, "the one strip must hold three thumbnails (png, md, svg), got \(thumbs.count)")
            try expect(thumbs.allSatisfy(\.hasPicture), "every thumbnail, the svg included, must be a real picture")
            print("file preview strip: three Writes in one turn draw one Changes card with three thumbnails; the edit keeps its card")
        }
        try groupedTurn()
        // 5. The RESTORE path: a persisted claude session with earlier text turns and
        //    one turn of three Writes is replayed the way the tile replays it
        //    (capture, ingest, bind), and must draw the text on both sides of ONE
        //    folded card. A fold that blanks a restored transcript fails here.
        func restoredTurn() throws {
            let sessionRoot = checkout.appendingPathComponent("outputs/strip", isDirectory: true)
            try fileManager.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
            let files: [(String, String)] = [("notes.md", "# Strip Notes\n\n## Purpose\n\nSample.\n"),
                                             ("landing.html", "<html><body><h1>Landing</h1></body></html>"),
                                             ("badge.svg", "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='120'><rect width='200' height='120' fill='#39c'/></svg>")]
            var lines: [String] = []
            func stamp(_ second: Int) -> String { String(format: "2026-11-24T05:41:%02d.000Z", second) }
            func line(_ object: [String: Any]) {
                if let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) { lines.append(text) }
            }
            line(["type": "user", "timestamp": stamp(1), "message": ["role": "user", "content": "First, say hello."]])
            line(["type": "assistant", "timestamp": stamp(2), "message": ["role": "assistant", "content": [["type": "text", "text": "Hello from the first turn."]]]])
            line(["type": "user", "timestamp": stamp(10), "message": ["role": "user", "content": "Now create three files."]])
            for (index, file) in files.enumerated() {
                let path = sessionRoot.appendingPathComponent(file.0)
                try Data(file.1.utf8).write(to: path)
                let id = "toolu_restore_\(index)"
                line(["type": "assistant", "timestamp": stamp(11 + index * 2), "message": ["role": "assistant", "content": [
                    ["type": "tool_use", "id": id, "name": "Write", "input": ["file_path": path.path, "content": file.1]]]]])
                line(["type": "user", "timestamp": stamp(12 + index * 2), "message": ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": id, "content": "File created successfully at: \(path.path)"]]]])
            }
            line(["type": "assistant", "timestamp": stamp(30), "message": ["role": "assistant", "content": [["type": "text", "text": "Done, all three files are written."]]]])

            let thread = "restore-thread"
            let transcript = ClaudeSessionTranscriptReader.parse(lines: lines, threadId: thread)
            try expect(!transcript.steps.isEmpty, "the restored session must reconstruct steps")
            // The real tile, restoring the way a relaunch does.
            let tile = ManagedAgentTileNSView(tile: Tile(
                id: UUID(), kind: .managedAgent, title: "restore", frame: TileFrame(x: 0, y: 0, width: 760, height: 760),
                zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
            tile.frame = NSRect(x: 0, y: 0, width: 760, height: 760)
            let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = tile
            window.orderFrontOffscreenForChecks()
            defer { window.orderOut(nil) }
            guard let canvas = tile.qaCanvasTranscript else { throw Failure(message: "the restored tile has no drawn transcript") }
            canvas.bindToolDetailAgent(AgentID(rawValue: UUID()))   // what attaching to the agent does
            tile.renderRehydratedPreviousSession(transcript)
            let settle = Date().addingTimeInterval(20)
            repeat {
                tile.layoutSubtreeIfNeeded(); canvas.flushPendingVisualUpdate(); canvas.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            } while (canvas.qaFileThumbs.count < 3 || canvas.qaFileThumbs.contains { !$0.hasPicture }) && Date() < settle
            let text = canvas.qaLaidOutText
            try expect(!canvas.qaPlacedBlockIDs.isEmpty, "a restored transcript with created files drew no blocks at all")
            try expect(text.contains("Hello from the first turn."), "the restored text before the files must still draw; drew '\(text.prefix(300))'")
            try expect(text.contains("Done, all three files are written."), "the restored text after the files must still draw; drew '\(text.prefix(300))'")
            let created = canvas.qaChangesCards.filter { $0.files.allSatisfy { $0.action == .write || $0.action == .add } }
            try expect(created.count == 1 && created[0].files.count == 3,
                       "the restored turn must draw one folded card of three files, got \(canvas.qaChangesCards.map { $0.files.count })")
            try expect(canvas.qaFileThumbs.count == 3, "the restored card must show three thumbnails, got \(canvas.qaFileThumbs.count)")
            print("file preview strip: a restored session draws its text around one folded card of three files")
        }
        try restoredTurn()
        // 6. A relaunch restores the document first and the host-local details later (or
        //    never): the cards then come from the tile's fallback presentation. Folding
        //    must hold on that path too, with text before and after.
        func fallbackTurn() throws {
            let canvas = AgentTranscriptCanvasView(toolDetailStore: AgentToolDetailStore())
            canvas.frame = NSRect(x: 0, y: 0, width: 1_100, height: 640)
            let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = canvas
            window.orderFrontOffscreenForChecks()
            try canvas.updateRenderContext(AgentRenderContext(actions: AgentRenderActions({ _ in }), tokens: .transcript, appearance: .dark))
            var projection = AgentTranscriptProjection(threadId: "fallback-thread")
            try projection.appendUserPrompt(id: AgentNodeID(rawValue: "fallback-user")!, text: "Before the files.")
            var entries = projection.document.entries
            var filesByBlock: [AgentNodeID: AgentDiffFileSummary] = [:]
            for (name, url) in [("shot", png), ("report", md), ("badge", svg)] {
                let block = AgentBlock(id: AgentNodeID(rawValue: "fallback-diff-\(name)")!, revision: 1, kind: .diff,
                                       payload: .diff(AgentDiffPayload(text: "", summary: "Write")))
                entries.append(AgentEntry(id: AgentNodeID(rawValue: "fallback-entry-\(name)")!, revision: 1, role: .assistant,
                                          provenance: .providerItem(provider: "runtime", itemID: "fb-\(name)"), blocks: [block]))
                filesByBlock[block.id] = AgentDiffFileSummary(displayName: url.lastPathComponent, addedLineCount: 4, action: .write, fileURL: url)
            }
            var closing = AgentTranscriptProjection(threadId: "fallback-thread-2")
            try closing.appendUserPrompt(id: AgentNodeID(rawValue: "fallback-user-2")!, text: "After the files.")
            entries += closing.document.entries
            canvas.setFallbackToolPresentation { block in
                guard case var .diff(payload) = block.payload, let file = filesByBlock[block.id] else { return nil }
                payload.files = [file]
                var presented = block; presented.payload = .diff(payload)
                return presented
            }
            let document = AgentDocument(version: 1, entries: entries)
            try canvas.enqueue(document: document, patch: AgentDocumentPatch(
                fromVersion: 0, toVersion: 1, inserted: document.entries.flatMap(\.blocks).map(\.id)), final: true)
            let settle = Date().addingTimeInterval(20)
            repeat {
                canvas.flushPendingVisualUpdate(); canvas.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            } while (canvas.qaFileThumbs.count < 3 || canvas.qaFileThumbs.contains { !$0.hasPicture }) && Date() < settle
            let text = canvas.qaLaidOutText
            try expect(!canvas.qaPlacedBlockIDs.isEmpty && text.contains("Before the files.") && text.contains("After the files."),
                       "a transcript whose cards come from the fallback presentation drew '\(text.prefix(200))'")
            try expect(canvas.qaChangesCards.count == 1 && canvas.qaChangesCards[0].files.count == 3,
                       "fallback-presented Writes must fold into one card of three files, got \(canvas.qaChangesCards.map { $0.files.count })")
            print("file preview strip: fallback-presented Writes fold into one card with the text around it")
        }
        try fallbackTurn()
        // 7. The path a relaunch really takes: the supervisor owns the restored session,
        //    and a tile ATTACHES to the agent. The body must build (text, composer) and
        //    draw one folded card, exactly as the neighbouring tile does.
        func sessionLines() throws -> [String] {
            let sessionRoot = checkout.appendingPathComponent("outputs/attached", isDirectory: true)
            try fileManager.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
            var lines: [String] = []
            func line(_ object: [String: Any]) {
                if let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) { lines.append(text) }
            }
            line(["type": "user", "timestamp": "2026-11-24T05:41:02.121Z", "message": ["role": "user", "content": "Create three files."]])
            line(["type": "assistant", "timestamp": "2026-11-24T05:41:04.414Z", "message": ["role": "assistant", "content": [["type": "text", "text": "Attached restore opening text."]]]])
            for (index, name) in ["notes.md", "landing.html", "badge.svg"].enumerated() {
                let path = sessionRoot.appendingPathComponent(name)
                try Data("x".utf8).write(to: path)
                let id = "toolu_attached_\(index)"
                line(["type": "assistant", "timestamp": "2026-11-24T05:43:5\(index).000Z", "message": ["role": "assistant", "content": [
                    ["type": "tool_use", "id": id, "name": "Write", "input": ["file_path": path.path, "content": "x"]]]]])
                line(["type": "user", "timestamp": "2026-11-24T05:43:5\(index).500Z", "message": ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": id, "content": "File created successfully at: \(path.path)"]]]])
            }
            line(["type": "assistant", "timestamp": "2026-11-24T05:44:10.000Z", "message": ["role": "assistant", "content": [["type": "text", "text": "Attached restore closing text."]]]])
            return lines
        }
        func attachedRestore() throws {
            let lines = try sessionLines()
            let support = tempRoot.appendingPathComponent("attached-support", isDirectory: true)
            let supervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: support),
                makeRunner: { _ in ScriptedAgentRunner(script: []) },
                transcriptStore: AgentTranscriptStore(root: support.appendingPathComponent("transcripts", isDirectory: true)))
            let tile = ManagedAgentTileNSView(tile: Tile(
                id: UUID(), kind: .managedAgent, title: "attached", frame: TileFrame(x: 0, y: 0, width: 760, height: 760),
                zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
            tile.frame = NSRect(x: 0, y: 0, width: 760, height: 760)
            let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = tile
            window.orderFrontOffscreenForChecks()
            defer { tile.detach(); window.orderOut(nil) }
            let id = supervisor.spawn(role: nil, prompt: nil, cwd: checkout, model: "anthropic/claude-haiku-4-5-20251001", thinking: "low")
            supervisor.seedRehydratedTranscript(
                ClaudeSessionTranscriptReader.parse(lines: lines, threadId: tile.qaThreadIdForChecks), for: id)
            tile.attach(agentID: id, supervisor: supervisor)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                tile.layoutSubtreeIfNeeded()
                tile.qaCanvasTranscript?.flushPendingVisualUpdate()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if (tile.qaCanvasTranscript?.qaFileThumbs.count ?? 0) >= 3 { break }
            }
            guard let canvas = tile.qaCanvasTranscript else { throw Failure(message: "the attached tile has no drawn transcript") }
            let text = canvas.qaLaidOutText
            try expect(text.contains("Attached restore opening text.") && text.contains("Attached restore closing text."),
                       "an attached restored tile must draw its text; drew '\(text.prefix(200))' (document entries \(tile.qaDocumentForChecks.entries.count))")
            let created = canvas.qaChangesCards.filter { $0.files.allSatisfy { $0.action == .write || $0.action == .add } }
            try expect(created.count == 1 && created[0].files.count == 3,
                       "an attached restored tile must fold its Writes into one card of three files, got \(canvas.qaChangesCards.map { $0.files.count })")
            print("file preview strip: a tile attached to a supervisor-restored session draws its text around one folded card")
        }
        try attachedRestore()
        // 8. The restore read lands AFTER the tile parked (a tile far off screen detaches while its
        //    session file is read). The history must still reach the tile that attaches next; it used to
        //    be dropped, leaving a tile with no transcript and no notice for good.
        func parkedDuringRead() throws {
            let lines = try sessionLines()
            let support = tempRoot.appendingPathComponent("parked-support", isDirectory: true)
            func makeSupervisor() -> AgentSupervisor {
                AgentSupervisor(
                    store: AgentStore(applicationSupportDirectory: support),
                    makeRunner: { _ in ScriptedAgentRunner(script: []) },
                    transcriptStore: AgentTranscriptStore(root: support.appendingPathComponent("transcripts", isDirectory: true)))
            }
            let id = makeSupervisor().spawn(role: nil, prompt: nil, cwd: checkout, model: "anthropic/claude-haiku-4-5-20251001", thinking: "low")
            let supervisor = makeSupervisor()
            _ = supervisor.restore()
            try expect(supervisor.wasRestored(id) && supervisor.needsPreviousSessionNotice(id), "the second supervisor must restore the agent")
            let tile = ManagedAgentTileNSView(tile: Tile(
                id: UUID(), kind: .managedAgent, title: "parked", frame: TileFrame(x: 0, y: 0, width: 760, height: 760),
                zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
            tile.frame = NSRect(x: 0, y: 0, width: 760, height: 760)
            let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = tile
            window.orderFrontOffscreenForChecks()
            defer { tile.detach(); window.orderOut(nil) }
            tile.attach(agentID: id, supervisor: supervisor)
            let threadId = tile.qaThreadIdForChecks
            let release = DispatchSemaphore(value: 0)
            let task = AppDelegate.restorePreviousSession(
                supervisor: supervisor, agentId: id, view: tile, stillCurrent: { true },
                read: {
                    release.wait()
                    return ClaudeSessionTranscriptReader.parse(lines: lines, threadId: threadId)
                })
            try expect(task != nil, "the restore read must start")
            tile.detach()          // the park, while the read is in flight
            release.signal()
            let landed = Date().addingTimeInterval(30)
            while supervisor.needsPreviousSessionNotice(id) && Date() < landed {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            try expect(supervisor.rehydratedTranscript(for: id) != nil, "a read that lands on a parked tile must still be seeded")
            tile.attach(agentID: id, supervisor: supervisor)   // the unpark
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                tile.layoutSubtreeIfNeeded()
                tile.qaCanvasTranscript?.flushPendingVisualUpdate()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if (tile.qaCanvasTranscript?.qaFileThumbs.count ?? 0) >= 3 { break }
            }
            guard let canvas = tile.qaCanvasTranscript else { throw Failure(message: "the unparked tile has no drawn transcript") }
            let text = canvas.qaLaidOutText
            try expect(text.contains("Attached restore opening text.") && text.contains("Attached restore closing text."),
                       "a tile that parked during its restore read must draw the history on return; drew '\(text.prefix(200))'")
            try expect(canvas.qaChangesCards.filter { $0.files.count == 3 }.count == 1,
                       "the restored history must fold into one card of three files, got \(canvas.qaChangesCards.map { $0.files.count })")
            print("file preview strip: a restore that lands on a parked tile still draws on return")
        }
        try parkedDuringRead()
        // 10. A Bash step whose command is a long heredoc (no description) must still read its
        //     real name and command after a restore, not a bare "Tool".
        func restoredLongBash() throws {
            let heredoc = "cd /tmp/long-bash-folder && mkdir -p outputs && cat > outputs/report.md <<'EOF'\n# Review Report\n\n## Summary\n\nA short test report.\nEOF\ncat > outputs/page.html <<'EOF'\n<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Welcome</title>\n<style>\n  body { margin: 0; font-family: system-ui, sans-serif; color: #1f2933; }\n  header { background: #2563eb; color: #fff; padding: 32px 24px; }\n</style>\n</head>\n<body><header><h1>Welcome</h1></header></body>\n</html>\nEOF\nls -la outputs"
            var lines: [String] = []
            func line(_ object: [String: Any]) {
                if let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) { lines.append(text) }
            }
            line(["type": "user", "timestamp": "2026-11-24T05:41:01.000Z", "message": ["role": "user", "content": "Run a command."]])
            line(["type": "assistant", "timestamp": "2026-11-24T05:41:02.000Z", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_long_1", "name": "Bash", "input": ["command": heredoc]]]]])
            line(["type": "user", "timestamp": "2026-11-24T05:41:03.000Z", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_long_1", "content": "total 0"]]]])
            line(["type": "assistant", "timestamp": "2026-11-24T05:41:06.000Z", "message": ["role": "assistant", "content": [["type": "text", "text": "Long bash closing text."]]]])
            let transcript = ClaudeSessionTranscriptReader.parse(lines: lines, threadId: "long-bash-thread")
            let tile = ManagedAgentTileNSView(tile: Tile(
                id: UUID(), kind: .managedAgent, title: "long", frame: TileFrame(x: 0, y: 0, width: 760, height: 760),
                zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
            tile.frame = NSRect(x: 0, y: 0, width: 760, height: 760)
            let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = tile
            window.orderFrontOffscreenForChecks()
            defer { window.orderOut(nil) }
            guard let canvas = tile.qaCanvasTranscript else { throw Failure(message: "the restored tile has no drawn transcript") }
            canvas.bindToolDetailAgent(AgentID(rawValue: UUID()))
            tile.renderRehydratedPreviousSession(transcript)
            let settle = Date().addingTimeInterval(20)
            repeat {
                tile.layoutSubtreeIfNeeded(); canvas.flushPendingVisualUpdate(); canvas.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            } while (canvas.toolDetail.qaHeldRecordCount < 1 || !canvas.qaLaidOutText.contains("Long bash closing text.")) && Date() < settle
            let tools = canvas.qaToolCalls
            let described = tools.map { "\($0.name)|\($0.presentedToolNameText ?? "-")|\($0.presentedShell?.command.prefix(30) ?? "-")|\(($0.summary ?? "-").prefix(30))" }
            try expect(tools.count == 1 && !tools[0].name.isEmpty && tools[0].name != "Tool" && (tools[0].presentedShell?.command.contains("long-bash-folder") ?? false),
                       "a restored long Bash step must keep its name and command; held \(canvas.toolDetail.qaHeldRecordCount); tool rows: \(described)")
            let row = canvas.qaVisibleTextLines.map(\.text).joined(separator: " | ")
            try expect(row.contains("Bash") || row.contains("long-bash-folder"), "the drawn row must say Bash or its command, drew '\(row.prefix(300))'")
            print("file preview strip: a restored long Bash step keeps its name and command")
        }
        try restoredLongBash()
        // 11. A Bash step on a tile attached to the supervisor (the path a relaunch takes), then
        //     parked and returned: its row keeps the real name and command throughout.
        func attachedBash() throws {
            var lines: [String] = []
            func line(_ object: [String: Any]) {
                if let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) { lines.append(text) }
            }
            line(["type": "user", "timestamp": "2026-11-24T05:41:01.000Z", "message": ["role": "user", "content": "Run a command."]])
            line(["type": "assistant", "timestamp": "2026-11-24T05:41:02.000Z", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_att_1", "name": "Bash", "input": ["command": "ls -la attached-folder", "description": "List the attached folder"]]]]])
            line(["type": "user", "timestamp": "2026-11-24T05:41:03.000Z", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_att_1", "content": "total 0"]]]])
            line(["type": "assistant", "timestamp": "2026-11-24T05:41:06.000Z", "message": ["role": "assistant", "content": [["type": "text", "text": "Attached bash closing text."]]]])
            let support = tempRoot.appendingPathComponent("attached-bash-support", isDirectory: true)
            let supervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: support),
                makeRunner: { _ in ScriptedAgentRunner(script: []) },
                transcriptStore: AgentTranscriptStore(root: support.appendingPathComponent("transcripts", isDirectory: true)))
            let tile = ManagedAgentTileNSView(tile: Tile(
                id: UUID(), kind: .managedAgent, title: "attached-bash", frame: TileFrame(x: 0, y: 0, width: 760, height: 760),
                zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
            tile.frame = NSRect(x: 0, y: 0, width: 760, height: 760)
            let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = tile
            window.orderFrontOffscreenForChecks()
            defer { tile.detach(); window.orderOut(nil) }
            let id = supervisor.spawn(role: nil, prompt: nil, cwd: checkout, model: "anthropic/claude-haiku-4-5-20251001", thinking: "low")
            supervisor.seedRehydratedTranscript(
                ClaudeSessionTranscriptReader.parse(lines: lines, threadId: tile.qaThreadIdForChecks), for: id)
            func rows(_ label: String) throws -> String {
                let deadline = Date().addingTimeInterval(20)
                while Date() < deadline {
                    tile.layoutSubtreeIfNeeded()
                    tile.qaCanvasTranscript?.flushPendingVisualUpdate()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    if (tile.qaCanvasTranscript?.toolDetail.qaHeldRecordCount ?? 0) >= 1,
                       tile.qaCanvasTranscript?.qaLaidOutText.contains("Attached bash closing text.") == true { break }
                }
                guard let canvas = tile.qaCanvasTranscript else { throw Failure(message: "no drawn transcript") }
                let tools = canvas.qaToolCalls
                let described = tools.map { "\($0.name)|\($0.presentedToolNameText ?? "-")|\($0.presentedShell?.command ?? "-")" }
                try expect(tools.count == 1 && tools[0].name.contains("Bash") || tools.first?.presentedShell?.command.contains("attached-folder") == true
                           || tools.first?.name.contains("attached") == true,
                           "\(label): a restored Bash step must keep its name and command; held \(canvas.toolDetail.qaHeldRecordCount); rows \(described)")
                return described.joined(separator: ";")
            }
            tile.attach(agentID: id, supervisor: supervisor)
            _ = try rows("attached")
            tile.detach()
            tile.attach(agentID: id, supervisor: supervisor)
            _ = try rows("re-attached after a park")
            print("file preview strip: a Bash step on an attached tile keeps its name and command across a park")
        }
        try attachedBash()
        // 9. Follow-ups on a restored transcript: a finished Bash step keeps its name and command,
        //    and a created file's count reads plainly ("+16"), never "≥ +16 −0" or "+4 −?".
        func restoredFollowups() throws {
            let sessionRoot = checkout.appendingPathComponent("outputs/followups", isDirectory: true)
            try fileManager.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
            let created = sessionRoot.appendingPathComponent("created.md")
            let body = (1...16).map { "line \($0)" }.joined(separator: "\n")
            try Data(body.utf8).write(to: created)
            let overwritten = sessionRoot.appendingPathComponent("overwritten.md")
            let overBody = (1...8).map { "row \($0)" }.joined(separator: "\n")
            try Data("old".utf8).write(to: overwritten)
            var lines: [String] = []
            func line(_ object: [String: Any]) {
                if let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) { lines.append(text) }
            }
            line(["type": "user", "timestamp": "2026-11-24T05:41:01.000Z", "message": ["role": "user", "content": "Run a command and write a file."]])
            line(["type": "assistant", "timestamp": "2026-11-24T05:41:02.000Z", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_bash_1", "name": "Bash", "input": ["command": "ls -la followup-folder", "description": "List the followup folder"]]]]])
            line(["type": "user", "timestamp": "2026-11-24T05:41:03.000Z", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_bash_1", "content": "total 0"]]]])
            line(["type": "assistant", "timestamp": "2026-11-24T05:41:04.000Z", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_write_1", "name": "Write", "input": ["file_path": created.path, "content": body]]]]])
            line(["type": "user", "timestamp": "2026-11-24T05:41:05.000Z", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_write_1", "content": "File created successfully at: \(created.path)"]]]])
            line(["type": "assistant", "timestamp": "2026-11-24T05:41:05.200Z", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_write_2", "name": "Write", "input": ["file_path": overwritten.path, "content": overBody]]]]])
            line(["type": "user", "timestamp": "2026-11-24T05:41:05.400Z", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_write_2", "content": "The file \(overwritten.path) has been updated successfully."]]]])
            line(["type": "assistant", "timestamp": "2026-11-24T05:41:06.000Z", "message": ["role": "assistant", "content": [["type": "text", "text": "Followups closing text."]]]])
            let transcript = ClaudeSessionTranscriptReader.parse(lines: lines, threadId: "followup-thread")
            let tile = ManagedAgentTileNSView(tile: Tile(
                id: UUID(), kind: .managedAgent, title: "followups", frame: TileFrame(x: 0, y: 0, width: 760, height: 760),
                zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
            tile.frame = NSRect(x: 0, y: 0, width: 760, height: 760)
            let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = tile
            window.orderFrontOffscreenForChecks()
            defer { window.orderOut(nil) }
            guard let canvas = tile.qaCanvasTranscript else { throw Failure(message: "the restored tile has no drawn transcript") }
            canvas.bindToolDetailAgent(AgentID(rawValue: UUID()))
            tile.renderRehydratedPreviousSession(transcript)
            let settle = Date().addingTimeInterval(20)
            repeat {
                tile.layoutSubtreeIfNeeded(); canvas.flushPendingVisualUpdate(); canvas.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            } while (!canvas.qaLaidOutText.contains("Followups closing text.") || canvas.toolDetail.qaHeldRecordCount < 2
                    || canvas.qaChangesCards.first?.files.isEmpty ?? true) && Date() < settle
            let text = canvas.qaLaidOutText
            let tools = canvas.qaToolCalls
            let bash = tools.first { ($0.presentedToolNameText ?? $0.name) == "Bash" || $0.name == "Bash" }
            try expect(bash != nil && (bash?.presentedShell?.command.contains("followup-folder") ?? false),
                       "a restored finished Bash step must keep its name and command; held \(canvas.toolDetail.qaHeldRecordCount) records, tool rows: \(tools.map { "\($0.name)|\($0.presentedToolNameText ?? "-")|\($0.presentedShell?.command ?? "-")|\($0.summary ?? "-")" })")
            let cards = canvas.qaChangesCards
            try expect(cards.count == 1 && cards[0].files.count == 2, "one created and one overwritten file must draw one card of two rows, got \(cards.map { $0.files.count })")
            let headline = AgentDiffSummaryView.countsText(cards[0].files)
            func row(_ name: String) -> String {
                guard let file = cards[0].files.first(where: { $0.displayName.hasSuffix(name) }) else { return "missing \(name)" }
                return AgentDiffSummaryView.statText(file, added: .green, removed: .red, unavailable: .gray).string
            }
            try expect(row("created.md") == "+16", "a created file's count must read plainly; row '\(row("created.md"))'")
            try expect(row("overwritten.md") != "+8" && row("overwritten.md") == "+8 · rewritten",
                       "an overwritten file must not read as created; row '\(row("overwritten.md"))'")
            try expect(headline == "2 files · +24 · 1 rewritten", "headline must not claim both were created; got '\(headline)'")
            print("file preview strip: a restored Bash step keeps its name and command; a created file's count reads plainly and an overwrite does not")
        }
        // 12. The LIVE stream decides creation from the Write's result, as the restore does.
        func liveWriteResults() throws {
            final class Box: @unchecked Sendable { var changes: [AgentToolDetailObservation.FileChange] = [] }
            let box = Box()
            var translator = ClaudeEventTranslator()
            translator.onRuntimeObservation = { observation in
                if case let .toolDetail(_, detail) = observation { box.changes += detail.fileChanges }
            }
            func send(_ object: [String: Any]) {
                guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
                _ = translator.translate(line: text)
            }
            for (id, name, result) in [("toolu_live_new", "fresh.md", "File created successfully at: /tmp/fresh.md"),
                                       ("toolu_live_over", "existing.md", "The file /tmp/existing.md has been updated successfully.")] {
                send(["type": "assistant", "message": ["role": "assistant", "content": [
                    ["type": "tool_use", "id": id, "name": "Write", "input": ["file_path": "/tmp/\(name)", "content": "a\nb\nc"]]]]])
                send(["type": "user", "message": ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": id, "content": result]]]])
            }
            let actions = Dictionary(grouping: box.changes, by: { ($0.path as NSString).lastPathComponent }).mapValues { Set($0.map { $0.action.rawValue }) }
            try expect(actions["fresh.md"]?.contains("add") == true, "a live Write whose result says created must publish an add; got \(actions)")
            try expect(actions["existing.md"]?.contains("add") != true, "a live Write whose result says updated must not publish an add; got \(actions)")
            print("file preview strip: a live Write is a creation only when its result says so")
        }
        try liveWriteResults()
        try restoredFollowups()
        try exercise(drawn: true)
        try exercise(drawn: false)
        print("file preview strip: thumbnails cached by mtime; opens in Array on both transcript renderers")
    }
}

#endif
