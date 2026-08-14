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
    static func runMarkdownPerformanceCheck() throws {
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

    // MARK: - Section 3: an agent's local-file link opens beside the agent

    /// Drives the real production chain — assistant Markdown → semantic link →
    /// `RichInlineTextView.activateLink` → the tile's own render action →
    /// `onOpenLocalFile` → `AgentLocalFileOpener` → `TileSpawner` — inside an
    /// isolated checkout, and proves authored content cannot escape that checkout.
    static func runAgentLocalFileLinkCheck() throws {
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

        let agentFrame = TileFrame(x: 100, y: 80, width: 460, height: 360)
        let agentTile = Tile(id: UUID(), kind: .managedAgent, title: "agent",
                             frame: agentFrame, zPosition: .fromLegacyRank(1),
                             runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed"))
        let agentView = ManagedAgentTileNSView(tile: agentTile, threadId: "thread-link")
        agentView.frame = NSRect(x: 0, y: 0, width: 460, height: 360)
        harness.canvas.installProjectTile(tileView: agentView, for: agentTile)
        agentView.layoutSubtreeIfNeeded()

        var refusals: [String] = []
        var opens: [AgentLocalFileOpener.Result] = []
        let opener = AgentLocalFileOpener(
            openFile: { path, placement in harness.runtime.openProjectFile(path: path, placement: placement) },
            fileTile: { [weak canvas = harness.canvas] tileId in canvas?.tileView(for: tileId) as? FileTileNSView }
        )
        agentView.onOpenLocalFile = { (destination: String) in
            let result = opener.open(destination: destination, checkoutRoot: checkout, sourceTileId: agentTile.id)
            opens.append(result)
            if case let .refused(reason) = result { refusals.append(reason) }
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

        var inlineViews: [RichInlineTextView] = []
        func walk(_ view: NSView) {
            if let inline = view as? RichInlineTextView { inlineViews.append(inline) }
            view.subviews.forEach(walk)
        }
        walk(agentView)
        let links = inlineViews.flatMap { view in view.linkRanges.map { (view: view, link: $0) } }
        try expect(!links.isEmpty, "the assistant message must render semantic links in the tile")

        func activate(_ destination: String) throws {
            guard let match = links.first(where: { $0.link.destination == destination }) else {
                throw Failure(message: "the transcript must contain a link to \(destination); it has \(links.map(\.link.destination))")
            }
            _ = match.view.activateLink(at: match.link.range.location)
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
        try expect(tile.zoneId == agentTile.zoneId || tile.zoneId == harness.zone,
                   "the file tile must inherit the responding agent tile's zone")

        // 3. Placement: top-aligned, exactly 24pt to the right of the agent.
        try expect(tile.frame.x == agentFrame.x + agentFrame.width + TileSpawner.anchoredFileGap,
                   "the file tile must sit exactly \(TileSpawner.anchoredFileGap)pt right of the agent tile; got x=\(tile.frame.x) against agent \(agentFrame)")
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

        // 5. The absolute and file:// spellings of the same file reveal that tile too.
        try activate(sourceFile.path)
        try activate("file://\(sourceFile.path)")
        try expect(harness.canvas.tileIds(inZone: harness.zone).count == before,
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
    }

    private struct SingleProjectHarness {
        let runtime: WorkspaceRuntime
        let canvas: CanvasNSView
        let focusBroker: FocusBroker
        let browserEngine: BrowserEngineContext
        let zone: UUID
    }

    private static func makeSingleProjectHarness(root: URL, tempRoot: URL) throws -> SingleProjectHarness {
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
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))

        let document = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [ZonePlacement(zoneId: zoneId, projectId: projectId, origin: ZonePoint(x: 0, y: 0),
                                  size: ZoneSize(width: 2_000, height: 1_400), color: "blue",
                                  collapsed: false, hydrationPolicy: .automatic)],
            zoneZOrder: [zoneId],
            lastActiveZoneId: zoneId
        )
        try WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).save(document)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceId
        appRegistry.projects = [ProjectEntry(id: projectId, name: "Worktree", rootPath: root.path,
                                             workspaceId: workspaceId, lastOpenedAt: now,
                                             pinned: false, missing: false)]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(appRegistry)

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
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: false
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 1_800, height: 1_200)
        try runtime.install(into: canvas, appRegistry: appRegistry)
        canvas.layoutSubtreeIfNeeded()
        return SingleProjectHarness(runtime: runtime, canvas: canvas, focusBroker: focusBroker,
                                    browserEngine: browserEngine, zone: zoneId)
    }

    // MARK: - Section 2: Markdown preview / source presentation

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
        try Data((0..<400).map { "\($0) \(longLine)" }.joined(separator: "\n").utf8).write(to: swiftURL)

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
        host.appearance = NSAppearance(named: .aqua)
        markdownTile.applyTokens()
        let lightColor = inlineColor(document)?.usingColorSpace(.sRGB)
        host.appearance = NSAppearance(named: .darkAqua)
        markdownTile.applyTokens()
        let darkColor = inlineColor(document)?.usingColorSpace(.sRGB)
        try expect(lightColor != nil && darkColor != nil && lightColor != darkColor,
                   "the Markdown document must repaint through appearance tokens (light \(String(describing: lightColor)) vs dark \(String(describing: darkColor)))")

        // Source shows the exact Markdown, in the same tile, without reloading.
        let identityBefore = markdownTile.tile.id
        let loadedBefore = markdownTile.loadedText
        markdownTile.setMode(.source)
        markdownTile.layoutSubtreeIfNeeded()
        try expect(markdownTile.mode == .source, "the mode control must switch the tile to Source")
        try expect(markdownTile.textView.string == sentinelMarkdown,
                   "Source must show the exact decoded Markdown")
        try expect(markdownTile.hasVisibleTextLayout(containing: "# Sentinel Report"),
                   "Source must lay the raw Markdown out visibly")
        try expect(markdownTile.tile.id == identityBefore, "switching modes must not change tile identity")
        try expect(markdownTile.loadedText == loadedBefore, "switching modes must reuse the one loaded snapshot")
        markdownTile.setMode(.preview)
        markdownTile.layoutSubtreeIfNeeded()
        try expect(markdownTile.mode == .preview && markdownTile.qaMarkdownDocument === document,
                   "switching back to Preview must reuse the same document view")

        // The control exists only for Markdown.
        try expect(markdownTile.qaModeControl != nil, "a markdown tile must offer a Preview/Source control")
        let swiftTile = makeTile(path: swiftURL.path)
        try expect(swiftTile.presentation == .sourceText, "a .swift tile must stay source-only")
        try expect(swiftTile.qaModeControl == nil, "a non-Markdown tile must have no mode control")
        try expect(swiftTile.qaMarkdownDocument == nil, "a non-Markdown tile must not build a Markdown document")
        let evidence = swiftTile.textVisibilityEvidence(containing: "let wide")
        try expect(evidence.visibleLayoutOK, "a source tile must still lay text out visibly: \(evidence)")
        try expect(evidence.longFileBehaviorOK,
                   "a long source file must keep vertical AND horizontal scrolling: \(evidence)")

        let decoyTile = makeTile(path: decoyURL.path)
        try expect(decoyTile.qaModeControl == nil, "a filename merely containing .md must not get Markdown treatment")

        // Reveal: a coordinate refers to the text, so a Markdown tile shows Source
        // and selects the named line.
        let revealTile = makeTile(path: markdownURL.path)
        revealTile.reveal(line: 6, column: 3)
        revealTile.layoutSubtreeIfNeeded()
        try expect(revealTile.mode == .source, "revealing a line in a Markdown tile must switch to Source")
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
    }
}
