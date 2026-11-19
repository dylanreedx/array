import AppKit
import ContinuumRevivedCore

/// A tile's corners show the diagonal resize cursor exactly where a drag
/// resizes both axes. Cursor rects are read from what `resetCursorRects`
/// really registers, and the drags go through `NSApp.sendEvent`.
@MainActor
enum ResizeCornerCursorChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private final class RecordingTileView: TileNSView {
        var rects: [(NSRect, NSCursor)] = []
        override func addCursorRect(_ rect: NSRect, cursor: NSCursor) {
            rects.append((rect, cursor))
            super.addCursorRect(rect, cursor: cursor)
        }
        /// AppKit lets the rect added last win where rects overlap.
        func cursor(at point: NSPoint) -> NSCursor? {
            rects.last(where: { $0.0.contains(point) })?.1
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func run() throws {
        for zoom in [1.0, 0.5] { try cursorRects(zoom: zoom) }
        try cornerDragResizesBothAxes()
    }

    private static func makeTile() -> Tile {
        Tile(id: UUID(), kind: .note, title: "CORNER", frame: TileFrame(x: 200, y: 200, width: 400, height: 300),
             zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
    }

    private static func cursorRects(zoom: Double) throws {
        let tile = makeTile()
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: zoom), tiles: [tile], groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        let view = RecordingTileView(tile: tile)
        canvas.install(tileView: view, for: tile)
        canvas.layoutSubtreeIfNeeded()
        view.rects = []
        view.resetCursorRects()

        let m = TileNSView.resizeMargin / CGFloat(zoom)
        let c = max(TileNSView.cornerHoverSize, 2 * m)
        let off = (m + c) / 2   // inside the corner band, outside the edge band
        let w = view.bounds.width, h = view.bounds.height
        let corners: [(String, NSPoint, ResizeEdge)] = [
            ("topLeft", NSPoint(x: off, y: off), .topLeft),
            ("topRight", NSPoint(x: w - off, y: off), .topRight),
            ("bottomLeft", NSPoint(x: off, y: h - off), .bottomLeft),
            ("bottomRight", NSPoint(x: w - off, y: h - off), .bottomRight),
        ]
        for (name, point, edge) in corners {
            try expect(view.qaResizeEdge(at: point) == edge, "zoom \(zoom): \(name) probe is not that corner's hit region")
            guard let cursor = view.cursor(at: point) else { throw Failure(description: "zoom \(zoom): \(name) has no cursor rect") }
            try expect(cursor != .resizeUpDown && cursor != .resizeLeftRight && cursor != .openHand && cursor != .arrow,
                       "zoom \(zoom): \(name) shows a non-diagonal cursor \(cursor) probe \(point) rects \(view.rects.map { "\($0.0)" })")
            try expect(cursor == ResizeCursors.cursor(for: edge), "zoom \(zoom): \(name) cursor is not the frame-resize cursor")
        }
        try expect(view.cursor(at: NSPoint(x: w / 2, y: m / 2)) == .resizeUpDown, "zoom \(zoom): top edge keeps up/down")
        try expect(view.cursor(at: NSPoint(x: w / 2, y: h - m / 2)) == .resizeUpDown, "zoom \(zoom): bottom edge keeps up/down")
        try expect(view.cursor(at: NSPoint(x: m / 2, y: h / 2)) == .resizeLeftRight, "zoom \(zoom): left edge keeps left/right")
        try expect(view.cursor(at: NSPoint(x: w - m / 2, y: h / 2)) == .resizeLeftRight, "zoom \(zoom): right edge keeps left/right")
    }

    private static func cornerDragResizesBothAxes() throws {
        let tile = makeTile()
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [tile], groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        let view = TileNSView(tile: tile)
        canvas.install(tileView: view, for: tile)
        canvas.layoutSubtreeIfNeeded()

        func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw Failure(description: "could not synthesize \(type)") }
            NSApp.sendEvent(event)
        }
        func frame() -> TileFrame { canvas.canvasState.tiles.first { $0.id == tile.id }!.frame }
        // Window y runs up; a pointer moving down the screen lowers window y.
        func drag(local: NSPoint, dx: CGFloat, dy: CGFloat) throws {
            let start = view.convert(local, to: nil)
            try send(.leftMouseDown, start)
            var p = start
            for _ in 0..<3 {
                p = NSPoint(x: p.x + dx / 3, y: p.y - dy / 3)
                try send(.leftMouseDragged, p)
            }
            try send(.leftMouseUp, p)
            canvas.layoutSubtreeIfNeeded()
        }
        let w = view.bounds.width, h = view.bounds.height
        let before = frame()
        try drag(local: NSPoint(x: w - 4, y: h - 4), dx: 60, dy: 40)
        let br = frame()
        try expect(br.width > before.width + 30 && br.height > before.height + 20,
                   "bottom-right corner drag must grow width and height; \(before) -> \(br)")
        try expect(br.x == before.x && br.y == before.y, "bottom-right drag must pin the top-left; \(before) -> \(br)")
        let v2 = canvas.tileView(for: tile.id) ?? view
        try drag(local: NSPoint(x: 4, y: 4), dx: 30, dy: 20)
        _ = v2
        let tl = frame()
        try expect(tl.width < br.width - 15 && tl.height < br.height - 10 && tl.x > br.x + 15 && tl.y > br.y + 10,
                   "top-left corner drag must shrink both axes from the top-left; \(br) -> \(tl)")
    }
}
