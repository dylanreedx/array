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
/// `TRANSCRIPT_CANVAS_PNG_DIR=<dir>` also writes a light and a dark review render
/// of a tile with a realistic transcript. The matrix does not set it.
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

    // MARK: Review renders

    private static func writeReviewRenders(to directory: URL, renderer: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let (tile, window) = makeTile(width: 460, height: 860)
            defer { window.orderOut(nil) }
            window.appearance = NSAppearance(named: appearance)
            guard let surface = tile.qaTranscriptSurface else { continue }
            let thread = "canvas"
            tile.appendUserPrompt("Can you find why the zoom stutters on my canvas and fix it? The agent tiles seem to be the slow part.")
            tile.ingest(.turnStarted(threadId: thread, turnId: "r1"))
            tile.ingest(.contentDelta(threadId: thread, turnId: "r1", streamKind: .assistant, delta: """
            I'll profile a real pinch first, then look at what each tile pays per frame.

            """))
            tile.ingest(.itemStarted(threadId: thread, itemId: "read-1", kind: .fileChange, title: "Read CanvasNSView.swift"))
            tile.ingest(.itemCompleted(threadId: thread, itemId: "read-1", kind: .fileChange, status: .completed))
            tile.ingest(.itemStarted(threadId: thread, itemId: "cmd-1", kind: .commandExecution, title: "swift build --product Array"))
            tile.ingest(.itemCompleted(threadId: thread, itemId: "cmd-1", kind: .commandExecution, status: .completed))
            tile.ingest(.contentDelta(threadId: thread, turnId: "r1", streamKind: .assistant, delta: """

            ## What the profile shows

            Array's own code is about **2%** of a zoom frame. The rest is *AppKit* re-laying out every view in every tile:

            - each agent tile is hundreds of views (`NSCollectionView`, cells, text views)
            - every zoom step re-rasterizes all of them
            - one view per tile reached 60-101 camera updates/s

            The fix draws the transcript in a single view, see [the plan](https://arrayapp.dev/plans/canvas):

            ```swift
            override func draw(_ dirtyRect: NSRect) {
                for line in visibleLines(in: dirtyRect) {
                    CTLineDraw(line.ctLine, context)
                }
            }
            ```

            1. Lay out each block once at the view's width.
            2. Draw only the lines inside the dirty rect.
            """))
            tile.ingest(.turnCompleted(threadId: thread, turnId: "r1", outcome: .completed, errorMessage: nil))
            settle(tile, surface)
            tile.layoutSubtreeIfNeeded()
            surface.scrollTranscript(toY: 0)
            tile.displayIfNeeded()
            let scale: CGFloat = 2
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(tile.bounds.width * scale), pixelsHigh: Int(tile.bounds.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = tile.bounds.size
            tile.cacheDisplay(in: tile.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let url = directory.appendingPathComponent("transcript-\(renderer)-\(name).png")
            try png.write(to: url)
            print("transcript canvas: wrote \(url.path)")
        }
    }
}
