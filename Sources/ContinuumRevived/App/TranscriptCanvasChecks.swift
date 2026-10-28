import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// `--transcript-canvas-check`: the one-view CoreText transcript
/// (`AgentTranscriptCanvasView`), driven through a REAL `ManagedAgentTileNSView`
/// with the renderer switch on and real `AgentRuntimeEvent`s, never the view in
/// isolation.
///
/// What it holds: the switch defaults to the row list; with it on, the tile's
/// transcript is the canvas view and has no subviews; streamed text is laid out;
/// a streaming delta re-lays out only the block it grew; a reader at the bottom
/// follows the tail, a reader scrolled up stays put, and Jump to latest returns;
/// a wheel scrolls it; a drag selects across blocks and Cmd-C copies exactly that
/// text; a click on a link reaches the tile's link handler; and a raised layer
/// `contentsScale` redraws the same lines at 2x and 4x with no layout at all —
/// the property a canvas zoom depends on.
///
/// Slice 2a, the drawn controls: through the PRODUCTION wiring (AppDelegate,
/// supervisor, a runner that can respond), a press on a drawn approval choice
/// reaches the transport exactly once with its decision; a drawn chevron expands
/// a tool row to its output and the state persists across a full re-layout; a
/// drawn code Copy copies the block; a capped code block scrolls sideways under a
/// horizontal wheel; the working gyro animates on a sublayer only while a turn
/// works; and the view still has no subviews.
///
/// `TRANSCRIPT_CANVAS_PNG_DIR=<dir>` also writes light and dark review renders of
/// both renderers on one transcript (approval, expanded failed tool, file-change
/// card). The matrix does not set it.
@MainActor
enum TranscriptCanvasChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func pump(_ seconds: TimeInterval = 0.12) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func run() throws {
        let key = AgentTranscriptCanvasView.rendererEnvironmentKey
        let previous = ProcessInfo.processInfo.environment[key]
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        unsetenv(key)
        try runDefaultIsTheRowList()
        setenv(key, "canvas", 1)
        try runCanvasRendererInTheTile()
        try runDrawnControlsInTheTile()
        try runApprovalPressReachesTheTransport()
        if let directory = ProcessInfo.processInfo.environment["TRANSCRIPT_CANVAS_PNG_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try writeReviewRenders(to: url, renderer: "canvas")
            // Today's row list on the same transcript, for comparison.
            unsetenv(key)
            try writeReviewRenders(to: url, renderer: "list")
        }
    }

    private static func makeTile(width: CGFloat, height: CGFloat) -> (ManagedAgentTileNSView, NSWindow) {
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "transcript-canvas",
            frame: TileFrame(x: 0, y: 0, width: Double(width), height: Double(height)),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")), threadId: "canvas")
        tile.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Room for the tile at 2x camera zoom: the canvas zooms a tile by scaling
        // its frame over fixed logical bounds, and the scale assertion does that.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width * 2, height: height * 2))
        host.addSubview(tile)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontOffscreenForChecks()
        tile.layoutSubtreeIfNeeded()
        return (tile, window)
    }

    private static func settle(_ tile: ManagedAgentTileNSView, _ surface: any AgentTranscriptSurface) {
        pump()
        tile.layoutSubtreeIfNeeded()
        surface.flushPendingVisualUpdate()
        tile.layoutSubtreeIfNeeded()
    }

    private static func runDefaultIsTheRowList() throws {
        guard UserDefaults.standard.string(forKey: AgentTranscriptCanvasView.rendererDefaultsKey) != "canvas" else {
            print("transcript canvas: the renderer default is set to canvas here; default-renderer assertion skipped")
            return
        }
        let (tile, window) = makeTile(width: 420, height: 400)
        defer { window.orderOut(nil) }
        try expect(tile.qaTranscriptSurface is AgentTranscriptListView,
                   "with the switch off the tile must keep the row list, got \(String(describing: tile.qaTranscriptSurface))")
    }

    private static func runCanvasRendererInTheTile() throws {
        let (tile, window) = makeTile(width: 420, height: 520)
        defer { window.orderOut(nil) }
        guard let surface = tile.qaTranscriptSurface as? AgentTranscriptCanvasView else {
            throw Failure(description: "with ARRAY_TRANSCRIPT_RENDERER=canvas the tile installed \(String(describing: tile.qaTranscriptSurface))")
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("array.transcript-canvas-check.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        surface.pasteboardForCopy = pasteboard
        surface.bindToolDetailAgent(AgentID(rawValue: UUID()))
        var opened: URL?
        tile.onOpenWebLink = { url, _ in opened = url }

        let thread = "canvas", turn = "t1"
        tile.appendUserPrompt("Explain the renderer.")
        tile.ingest(.turnStarted(threadId: thread, turnId: turn))
        tile.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant,
                                  delta: "First paragraph of the answer, see [the docs](https://example.com/docs).\n\nSecond paragraph begins"))
        settle(tile, surface)
        try expect(surface.subviews.isEmpty, "the canvas transcript must have no subviews, has \(surface.subviews.count)")
        var text = surface.qaLaidOutText
        try expect(text.contains("Explain the renderer.") && text.contains("First paragraph of the answer")
                   && text.contains("Second paragraph begins"),
                   "the streamed text was not laid out: \(text.debugDescription)")

        // A delta that grows the open paragraph re-lays out that block alone.
        let layoutsBefore = surface.qaBlockLayoutCount
        tile.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant, delta: " and keeps streaming."))
        settle(tile, surface)
        text = surface.qaLaidOutText
        try expect(text.contains("Second paragraph begins and keeps streaming."),
                   "the second delta was not laid out: \(text.debugDescription)")
        let relaid = surface.qaBlockLayoutCount - layoutsBefore
        try expect(relaid == 1 && surface.qaLastRelaidBlockIDs == [surface.qaPlacedBlockIDs.last].compactMap { $0 },
                   "a streaming delta must re-lay out only the tail block; it laid out \(relaid) block(s) "
                   + "\(surface.qaLastRelaidBlockIDs) of \(surface.qaPlacedBlockIDs.count)")

        // A tool item lands as its collapsed row.
        tile.ingest(.itemStarted(threadId: thread, itemId: "tool-1", kind: .commandExecution, title: "Run the tests"))
        tile.ingest(.itemCompleted(threadId: thread, itemId: "tool-1", kind: .commandExecution, status: .completed))
        settle(tile, surface)
        let toolBlock = tile.qaDocumentForChecks.entries.flatMap(\.blocks).first { $0.kind == .toolCall }
        guard let toolBlock, case let .toolCall(tool) = toolBlock.payload else {
            throw Failure(description: "the tool item produced no tool block in the tile's document")
        }
        try expect(surface.qaPlacedBlockIDs.contains(toolBlock.id)
                   && surface.qaLaidOutText.contains(ToolCallView.safeSingleLine(tool.name, fallback: "Tool")),
                   "the tool row '\(tool.name)' was not laid out")

        // Bottom-follow: fill past the viewport while the reader is at the bottom.
        for index in 0..<24 {
            tile.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant,
                                      delta: "\n\nFollow paragraph \(index) carries enough words to wrap across the column."))
            settle(tile, surface)
        }
        try expect(surface.qaMaximumScrollOffset > 200,
                   "the transcript must overflow its viewport for the scroll assertions; max offset \(surface.qaMaximumScrollOffset)")
        try expect(surface.qaScrollOffset == surface.qaMaximumScrollOffset,
                   "a reader at the bottom must follow the tail: offset \(surface.qaScrollOffset) of \(surface.qaMaximumScrollOffset)")

        // A wheel over the transcript scrolls it.
        let bottom = surface.qaScrollOffset
        if let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 40, wheel2: 0, wheel3: 0),
           let wheel = NSEvent(cgEvent: cgEvent) {
            surface.scrollWheel(with: wheel)
        }
        try expect(surface.qaScrollOffset < bottom && surface.qaScrollOffset > 0,
                   "a wheel up must scroll the transcript up: \(bottom) -> \(surface.qaScrollOffset)")

        // A reader scrolled up keeps their place while content streams.
        surface.scrollTranscript(toY: 0)
        let maxBefore = surface.qaMaximumScrollOffset
        tile.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant,
                                  delta: "\n\nArrived while the reader was scrolled up."))
        settle(tile, surface)
        try expect(surface.qaMaximumScrollOffset > maxBefore && surface.qaScrollOffset == 0,
                   "a scrolled-up reader must stay put: offset \(surface.qaScrollOffset), max \(maxBefore) -> \(surface.qaMaximumScrollOffset)")
        surface.jumpToLatest()
        try expect(surface.qaScrollOffset == surface.qaMaximumScrollOffset,
                   "Jump to latest must reach the bottom: \(surface.qaScrollOffset) of \(surface.qaMaximumScrollOffset)")

        // Drag-select across two blocks through the window's event path, then
        // Cmd-C through the responder chain.
        surface.scrollTranscript(toY: 0)
        let laid = surface.qaLaidOutText as NSString
        let start = laid.range(of: "First paragraph").location
        let secondStart = laid.range(of: "Second paragraph").location
        try expect(start != NSNotFound && secondStart != NSNotFound, "selection anchors are missing from the laid text")
        let end = secondStart + "Second".utf16.count
        guard let from = surface.qaPoint(forCharacterIndex: start),
              let to = surface.qaPoint(forCharacterIndex: end) else {
            throw Failure(description: "no points for the selection anchors")
        }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: surface.convert(point, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        window.sendEvent(mouse(.leftMouseDown, from))
        window.sendEvent(mouse(.leftMouseDragged, to))
        window.sendEvent(mouse(.leftMouseUp, to))
        try expect(window.firstResponder === surface,
                   "a press on the transcript must make it first responder, got \(String(describing: window.firstResponder))")
        let expected = "First paragraph of the answer, see the docs.\nSecond"
        try expect(surface.selectedText == expected,
                   "the drag selected \(String(describing: surface.selectedText).debugDescription), expected \(expected.debugDescription)")
        try expect(window.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil) == true,
                   "Cmd-C found no copy: in the responder chain")
        try expect(pasteboard.string(forType: .string) == expected,
                   "Cmd-C copied \(String(describing: pasteboard.string(forType: .string)).debugDescription)")

        // A click on the link opens it through the tile's link handler.
        let linkIndex = laid.range(of: "the docs").location + 2
        guard let linkPoint = surface.qaPoint(forCharacterIndex: linkIndex) else {
            throw Failure(description: "no point for the link")
        }
        window.sendEvent(mouse(.leftMouseDown, linkPoint))
        window.sendEvent(mouse(.leftMouseUp, linkPoint))
        try expect(opened?.absoluteString == "https://example.com/docs",
                   "a click on the link must reach onOpenWebLink, got \(String(describing: opened))")

        // A canvas zoom scales the tile's frame over its fixed logical bounds
        // (`CanvasNSView.applyTileGeometry`). AppKit raises the layer's
        // contentsScale to match; the same lines redraw sharp at that scale and
        // nothing is laid out again.
        try expect(surface.layer != nil && surface.layerContentsRedrawPolicy == .onSetNeedsDisplay,
                   "the canvas transcript must be layer-backed and redraw only on setNeedsDisplay")
        let layoutsAtRest = surface.qaBlockLayoutCount
        let fullRelayouts = surface.qaFullRelayoutCount
        let logical = tile.bounds
        let backing = window.backingScaleFactor
        for scale: CGFloat in [2, 4] {
            let zoom = scale / backing
            let draws = surface.qaDrawCount
            tile.setFrameSize(NSSize(width: logical.width * zoom, height: logical.height * zoom))
            tile.bounds = logical
            tile.layoutSubtreeIfNeeded()
            surface.needsDisplay = true
            window.displayIfNeeded()
            // Core Animation draws a layer-backed view at its next display pass,
            // which an offscreen fixture has to ask for.
            surface.layer?.displayIfNeeded()
            try expect(surface.qaDrawCount > draws && abs(surface.qaLastDrawScale - scale) < 0.01,
                       "at camera zoom \(zoom) (backing \(backing)) the view drew \(surface.qaDrawCount - draws) time(s) "
                       + "at scale \(surface.qaLastDrawScale), layer contentsScale \(surface.layer?.contentsScale ?? 0); expected \(scale)")
            try expect(surface.qaLastDrawnLineCount > 0, "the \(scale)x draw stroked no lines")
        }
        try expect(surface.qaBlockLayoutCount == layoutsAtRest && surface.qaFullRelayoutCount == fullRelayouts,
                   "a zoom must not lay anything out: \(surface.qaBlockLayoutCount - layoutsAtRest) block layouts")
        tile.setFrameSize(logical.size)
        tile.bounds = logical

        tile.ingest(.turnCompleted(threadId: thread, turnId: turn, outcome: .completed, errorMessage: nil))
        settle(tile, surface)
        try expect(surface.subviews.isEmpty, "the canvas transcript grew subviews: \(surface.subviews.count)")
        try expect(surface.qaRenderingErrorDescription == nil, "rendering error: \(surface.qaRenderingErrorDescription ?? "")")
        print("transcript canvas: tile installs a subview-free canvas; a delta re-laid out 1 block; "
              + "tail follow, wheel, scrolled-up hold and jump hold; drag + Cmd-C copied \(expected.debugDescription); "
              + "link opened; redrew at 2x and 4x with 0 layouts")
    }

    // MARK: Slice 2a: drawn controls

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// A press and release on a drawn control, through the window's event path.
    private static func click(_ point: NSPoint, on view: NSView, window: NSWindow) {
        window.sendEvent(mouse(.leftMouseDown, at: point, in: view, window: window))
        window.sendEvent(mouse(.leftMouseUp, at: point, in: view, window: window))
    }

    private static func waitFor(_ seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            pump(0.03)
        }
        return condition()
    }

    private static func runDrawnControlsInTheTile() throws {
        let (tile, window) = makeTile(width: 460, height: 640)
        defer { window.orderOut(nil) }
        guard let surface = tile.qaTranscriptSurface as? AgentTranscriptCanvasView else {
            throw Failure(description: "the canvas switch did not install the canvas transcript")
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("array.transcript-canvas-check.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        surface.pasteboardForCopy = pasteboard
        surface.bindToolDetailAgent(AgentID(rawValue: UUID()))
        let thread = "canvas", turn = "t2"
        tile.ingest(.turnStarted(threadId: thread, turnId: turn))
        surface.setTurnInFlight(true)
        surface.setThinkingIndicatorVisible(true)
        try expect(surface.qaGyroIsAnimating && surface.qaGyroLayer.superlayer === surface.layer
                   && !(surface.qaGyroLayer.sublayers ?? []).compactMap({ $0.animationKeys() }).flatMap({ $0 }).isEmpty,
                   "a working tail must animate its gyro on a sublayer of the transcript's own layer")

        // A failed tool with output: a drawn chevron, which expands to the output.
        tile.ingest(.itemStarted(threadId: thread, itemId: "cmd-1", kind: .commandExecution, title: "swift test"))
        surface.captureRuntimeObservation(.toolDetail(itemId: "cmd-1", detail: AgentToolDetailObservation(
            phase: .ended, toolName: "Bash", fields: [(key: "command", value: "swift test")],
            outputPreview: "Executed 14 tests, with 1 failure\nXCTAssertEqual failed: (3) is not equal to (2)",
            exitCode: 1, observedAt: Date())))
        tile.ingest(.itemCompleted(threadId: thread, itemId: "cmd-1", kind: .commandExecution, status: .completed))
        settle(tile, surface)
        guard let toolID = tile.qaDocumentForChecks.entries.flatMap(\.blocks).first(where: { $0.kind == .toolCall })?.id else {
            throw Failure(description: "the tool item produced no tool block")
        }
        try expect(waitFor { surface.qaControls.contains { $0.blockID == toolID && $0.kind == "chevron.collapsed" } },
                   "a completed tool with output must draw a collapsed disclosure chevron; controls \(surface.qaControls.map(\.kind))")
        let collapsedHeight = surface.qaHeight(of: toolID) ?? 0
        surface.qaReveal(blockID: toolID)
        guard let chevron = surface.qaControls.first(where: { $0.blockID == toolID && $0.kind.hasPrefix("chevron") }) else {
            throw Failure(description: "no chevron to press")
        }
        click(chevron.center, on: surface, window: window)
        tile.layoutSubtreeIfNeeded()
        try expect(surface.qaControls.contains { $0.blockID == toolID && $0.kind == "chevron.expanded" }
                   && (surface.qaHeight(of: toolID) ?? 0) > collapsedHeight + 40
                   && surface.qaLaidOutText.contains("XCTAssertEqual failed"),
                   "pressing the chevron must expand the tool row to its output: height \(collapsedHeight) -> "
                   + "\(surface.qaHeight(of: toolID) ?? 0), controls \(surface.qaControls.filter { $0.blockID == toolID }.map(\.kind))")
        // Presenting a tool row is redaction and string work; a rebuild of an
        // unchanged transcript must not repeat it for every row (it ran a
        // transcript's worth on each update and at every turn end).
        let presentedBefore = surface.toolDetail.qaPresentationCount
        try expect(presentedBefore > 0, "no tool row was presented from its detail; the assertion is vacuous")
        surface.rebuild()
        try expect(surface.toolDetail.qaPresentationCount == presentedBefore,
                   "rebuilding an unchanged transcript presented \(surface.toolDetail.qaPresentationCount - presentedBefore) tool row(s) again")
        // Persists: a theme flip makes the tile push a new context, which drops
        // every cached layout; the row must come back open.
        let layoutsBeforeFlip = surface.qaBlockLayoutCount
        window.appearance = NSAppearance(named: window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .aqua : .darkAqua)
        _ = waitFor(2) { tile.layoutSubtreeIfNeeded(); return surface.qaBlockLayoutCount > layoutsBeforeFlip }
        try expect(surface.qaBlockLayoutCount > layoutsBeforeFlip
                   && surface.qaControls.contains { $0.blockID == toolID && $0.kind == "chevron.expanded" },
                   "the expanded tool row must stay expanded across a full re-layout (re-laid \(surface.qaBlockLayoutCount - layoutsBeforeFlip) blocks)")

        // A code block past today's 320pt cap, with one long line.
        let longLine = "let value = " + String(repeating: "alpha + beta + ", count: 30) + "omega"
        let code = (0..<40).map { "line \($0)" }.joined(separator: "\n") + "\n" + longLine
        tile.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant, delta: "Here:\n\n```swift\n\(code)\n```\n"))
        tile.ingest(.turnCompleted(threadId: thread, turnId: turn, outcome: .completed, errorMessage: nil))
        settle(tile, surface)
        guard let codeBlock = tile.qaDocumentForChecks.entries.flatMap(\.blocks).first(where: { $0.kind == .fencedCode }),
              case let .fencedCode(payload) = codeBlock.payload else {
            throw Failure(description: "the fenced code produced no code block")
        }
        let cap = CodeBlockView.maximumExpandedHeight(zoom: .default)
        try expect(abs((surface.qaHeight(of: codeBlock.id) ?? 0) - cap) < 1,
                   "a long code block must stop at today's \(cap)pt cap, is \(surface.qaHeight(of: codeBlock.id) ?? 0)")
        surface.qaReveal(blockID: codeBlock.id)
        guard let copy = surface.qaControls.first(where: { $0.blockID == codeBlock.id && $0.title == "Copy" }) else {
            throw Failure(description: "the code block drew no Copy control")
        }
        click(copy.center, on: surface, window: window)
        try expect(pasteboard.string(forType: .string) == payload.code,
                   "the drawn code Copy must copy the whole block, got \(String(describing: pasteboard.string(forType: .string)?.prefix(40)))")
        // Sideways scroll over the code body moves only that block.
        let inside = NSPoint(x: copy.center.x - 100, y: copy.center.y + 60)
        let offsetBefore = surface.qaScrollOffset
        if let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -60, wheel3: 0) {
            // A synthesized wheel has no window, so its locationInWindow is the
            // CG location flipped into Cocoa space: aim that at the window point.
            let target = surface.convert(inside, to: nil)
            cgEvent.location = CGPoint(x: target.x, y: (NSScreen.screens.first?.frame.height ?? 0) - target.y)
            if let wheel = NSEvent(cgEvent: cgEvent) { surface.scrollWheel(with: wheel) }
        }
        let codeOffset = surface.qaRegionOffsets.first { $0.key.blockID == codeBlock.id }?.value ?? .zero
        try expect(codeOffset.x > 0 && surface.qaScrollOffset == offsetBefore,
                   "a horizontal wheel over a wide code block must scroll the block sideways, not the transcript: "
                   + "block offset \(codeOffset), transcript \(offsetBefore) -> \(surface.qaScrollOffset)")

        surface.setThinkingIndicatorVisible(false)
        try expect(!surface.qaGyroIsAnimating, "the gyro must stop when the tail is no longer working")
        try expect(surface.subviews.isEmpty, "the canvas transcript grew subviews: \(surface.subviews)")
        print("transcript canvas 2a: chevron expanded a tool row to its output and it survived a re-layout; "
              + "code capped at \(Int(cap))pt, Copy copied \(payload.code.count) characters, a sideways wheel scrolled "
              + "the block only; the gyro animated on a sublayer and stopped; still 0 subviews")
    }

    // MARK: Production wiring

    private struct Wired {
        let delegate: AppDelegate
        let supervisor: AgentSupervisor
        let tile: ManagedAgentTileNSView
        let window: NSWindow
        let agentID: AgentID
        let temporary: URL
    }

    /// `ProviderRequestResponseChecks`' fixture: a real delegate, canvas,
    /// supervisor and tile joined by `wireManagedAgentTile`, parked off screen.
    /// `firstPrompt` is sent BEFORE the tile is wired: the tile reads the runner's
    /// response capability into its render context when it attaches, and does
    /// not re-push it when the capability later appears, so a request block only
    /// draws its choices if the runner was live at attach.
    private static func makeWired(runner: ProviderRequestResponseChecks.RespondingRunner, firstPrompt: String,
                                  width: Double = 520, height: Double = 420) throws -> Wired {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("array-transcript-canvas-\(UUID().uuidString)", isDirectory: true)
        let appSupport = temporary.appendingPathComponent("support", isDirectory: true)
        let agentsSupport = temporary.appendingPathComponent("agents", isDirectory: true)
        let projectRoot = temporary.appendingPathComponent("project", isDirectory: true)
        for dir in [appSupport, agentsSupport, projectRoot] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let now = Date()
        let tileID = UUID()
        let agentID = AgentID(rawValue: UUID())
        let store = AgentStore(applicationSupportDirectory: agentsSupport)
        try store.upsert(AgentRecord(id: agentID, displayName: "canvas agent", role: "reviewer",
                                     model: "openai-codex/gpt-5.6-sol", thinking: "medium", cwd: projectRoot.path,
                                     projectId: UUID(), createdAt: now, lastActivityAt: now, tileId: tileID))
        let tile = Tile(id: tileID, kind: .managedAgent, title: "canvas agent",
                        frame: TileFrame(x: 0, y: 0, width: width, height: height),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil,
                        metadata: TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: "."))
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [tile],
                                                           groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: width + 80, height: height + 80)
        let delegate = AppDelegate()
        canvas.focusBroker = delegate.focusBroker
        canvas.occlusionVisibilityProvider = { true }
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        let tileView = ManagedAgentTileNSView(tile: tile)
        canvas.install(tileView: tileView, for: tile)
        canvas.layoutSubtreeIfNeeded()
        delegate.canvasView = canvas
        delegate.registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        delegate.agentSupervisor = AgentSupervisor(store: store, makeRunner: { _ in runner })
        delegate.agentSupervisor.restore()
        _ = delegate.agentSupervisor.send(firstPrompt, to: agentID)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        delegate.installAcceptedTileFocusHook()
        delegate.wireManagedAgentTile(tileID, agentID: agentID)
        return Wired(delegate: delegate, supervisor: delegate.agentSupervisor, tile: tileView, window: window,
                     agentID: agentID, temporary: temporary)
    }

    private static func runApprovalPressReachesTheTransport() throws {
        let runner = ProviderRequestResponseChecks.RespondingRunner()
        let wired = try makeWired(runner: runner, firstPrompt: "open a request")
        defer {
            wired.window.orderOut(nil)
            try? FileManager.default.removeItem(at: wired.temporary)
        }
        guard let surface = wired.tile.qaTranscriptSurface as? AgentTranscriptCanvasView else {
            throw Failure(description: "the wired tile did not install the canvas transcript")
        }
        let thread = AgentSupervisor.threadId(for: wired.agentID)
        wired.supervisor.qaDeliver(.requestOpened(threadId: thread, requestId: "req-canvas", kind: .commandExecutionApproval),
                                   to: wired.agentID)
        let declineTitle = ApprovalDecision.displayTitle(forChoice: ApprovalDecision.decline.rawValue)
        let drawn = waitFor {
            surface.flushPendingVisualUpdate()
            wired.tile.layoutSubtreeIfNeeded()
            return surface.qaControls.contains { $0.kind == "choice" && $0.title == declineTitle }
        }
        try expect(drawn, "the approval row drew no '\(declineTitle)' choice; controls \(surface.qaControls.map { "\($0.kind):\($0.title)" }), "
                   + "requests \(wired.tile.qaV2RequestIDs), placed \(surface.qaPlacedBlockIDs.count), bounds \(surface.bounds), "
                   + "can respond \(wired.supervisor.turnSnapshot(for: wired.agentID)?.capabilities.canRespondToRequests == true), "
                   + "error \(surface.qaRenderingErrorDescription ?? "-"), entries \(wired.tile.qaDocumentForChecks.entries.map { "\($0.role):\($0.blocks.map(\.kind.rawValue))" }), "
                   + "laid \(surface.qaLaidOutText.debugDescription)")
        surface.jumpToLatest()
        guard let decline = surface.qaControls.first(where: { $0.kind == "choice" && $0.title == declineTitle }) else {
            throw Failure(description: "the decline choice vanished")
        }
        click(decline.center, on: surface, window: wired.window)
        try expect(waitFor { runner.delivered.count == 1 },
                   "a press on the drawn decline choice never reached the transport (delivered \(runner.delivered))")
        try expect(runner.delivered[0].0 == "req-canvas" && runner.delivered[0].1 == .decline,
                   "the press delivered \(runner.delivered), expected req-canvas/decline")
        try expect(wired.tile.qaV2RequestResponseState("req-canvas") == .submitting,
                   "the dispatched response left no in-flight state on the request")
        try expect(surface.subviews.isEmpty, "the canvas transcript grew subviews: \(surface.subviews)")
        print("transcript canvas 2a: a press on the drawn decline choice reached the transport once (req-canvas/decline)")
    }

    // MARK: Review renders

    private static func writeReviewRenders(to directory: URL, renderer: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let runner = ProviderRequestResponseChecks.RespondingRunner()
            let wired = try makeWired(runner: runner, firstPrompt: "Run the parser tests and fix the failing one.",
                                      width: 460, height: 900)
            defer {
                wired.window.orderOut(nil)
                try? FileManager.default.removeItem(at: wired.temporary)
            }
            wired.window.appearance = NSAppearance(named: appearance)
            guard let surface = wired.tile.qaTranscriptSurface else { continue }
            let deliver = { (event: AgentRuntimeEvent) in wired.supervisor.qaDeliver(event, to: wired.agentID) }
            let thread = AgentSupervisor.threadId(for: wired.agentID)
            // Tool items go straight to the tile, as the bare-tile assertions
            // drive them, so the host-local detail (output, files) binds to the
            // rows the same way in both renderers. The prompt went out before the tile was wired; show it the way a
            // live send does.
            wired.tile.appendUserPrompt("Run the parser tests and fix the failing one.")
            deliver(.turnStarted(threadId: thread, turnId: "r1"))
            let tileThread = wired.tile.qaThreadIdForChecks
            wired.tile.ingest(.turnStarted(threadId: tileThread, turnId: "r1"))
            deliver(.contentDelta(threadId: thread, turnId: "r1", streamKind: .assistant,
                                  delta: "I'll run the **parser** tests first.\n\n"))
            wired.tile.ingest(.itemStarted(threadId: tileThread, itemId: "cmd-1", kind: .commandExecution, title: "swift test --filter Parser"))
            surface.captureRuntimeObservation(.toolDetail(itemId: "cmd-1", detail: AgentToolDetailObservation(
                phase: .started, toolName: "Bash", fields: [(key: "command", value: "swift test --filter Parser")],
                observedAt: Date())))
            surface.captureRuntimeObservation(.toolDetail(itemId: "cmd-1", detail: AgentToolDetailObservation(
                phase: .ended, toolName: "Bash",
                outputPreview: "Test Suite 'ParserTests' started\n✗ testNestedLists (0.012s)\n  XCTAssertEqual failed: (\"3\") is not equal to (\"2\")\nExecuted 14 tests, with 1 failure",
                exitCode: 1, observedAt: Date())))
            wired.tile.ingest(.itemCompleted(threadId: tileThread, itemId: "cmd-1", kind: .commandExecution, status: .failed))
            wired.tile.ingest(.itemStarted(threadId: tileThread, itemId: "edit-1", kind: .fileChange, title: "Edit MarkdownParser.swift"))
            surface.captureRuntimeObservation(.toolDetail(itemId: "edit-1", detail: AgentToolDetailObservation(
                phase: .ended, toolName: "Edit",
                fileChanges: [.init(action: .edit, path: "Sources/Parser/MarkdownParser.swift", addedLines: 4, removedLines: 1)],
                observedAt: Date())))
            wired.tile.ingest(.itemCompleted(threadId: tileThread, itemId: "edit-1", kind: .fileChange, status: .completed))
            deliver(.contentDelta(threadId: thread, turnId: "r1", streamKind: .assistant,
                                  delta: "The nested list case counted its marker twice; `MarkdownParser` now skips it. "
                                    + "I'd like to run the full suite to confirm."))
            deliver(.requestOpened(threadId: thread, requestId: "req-1", kind: .commandExecutionApproval))
            _ = waitFor(3) {
                surface.flushPendingVisualUpdate()
                wired.tile.layoutSubtreeIfNeeded()
                return wired.tile.qaV2RequestIDs.contains("req-1")
            }
            pump(0.5)
            surface.flushPendingVisualUpdate()
            wired.tile.layoutSubtreeIfNeeded()
            surface.scrollTranscript(toY: 0)
            wired.tile.displayIfNeeded()
            let scale: CGFloat = 2
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(wired.tile.bounds.width * scale), pixelsHigh: Int(wired.tile.bounds.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = wired.tile.bounds.size
            wired.tile.cacheDisplay(in: wired.tile.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let url = directory.appendingPathComponent("transcript-\(renderer)-\(name).png")
            try png.write(to: url)
            print("transcript canvas: wrote \(url.path)")
        }
    }
}
