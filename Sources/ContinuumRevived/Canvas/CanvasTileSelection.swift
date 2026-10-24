import AppKit
import ContinuumRevivedCore

/// Ephemeral workspace selection. Keyboard focus continues to belong to one
/// surface. Native body events and reference dragging never enter this owner.
@MainActor
final class CanvasTileSelection {
    weak var canvas: CanvasNSView?
    private(set) var ids: Set<UUID> = []
    private var overlay: TileSelectionOverlay?
    private var consumedHeaderClick = false
    private var worldFrames: [TileFrame] = []
    private struct Gesture {
        let snapshot: TileSelectionGeometry.Snapshot
        let start: NSPoint
        let zoom: Double
        let edge: ResizeEdge?
        /// The member whose title bar was pressed; nil for the group handles.
        let pressedTileId: UUID?
        var moved = false
        var lastDelta: CGSize = .zero
    }
    private var gesture: Gesture?
    var ownsPointer: Bool { consumedHeaderClick || gesture != nil }
    private(set) var batchUpdates = 0

    init(canvas: CanvasNSView) { self.canvas = canvas }

    func preparePointerDown() {
        cancel()
        consumedHeaderClick = false
    }

    func selectOnly(_ id: UUID?) {
        guard gesture == nil else { return }
        ids = id.map { [$0] } ?? []
        refresh()
    }

    func clear() {
        cancel()
        consumedHeaderClick = false
        ids.removeAll()
        refresh()
    }

    /// Called only after camera pan has had first refusal. The native resize
    /// ring selects one tile; group resizing has its own explicit outer handles.
    func mouseDown(on tile: TileNSView, event: NSEvent, isHeader: Bool, isResize: Bool) -> Bool {
        guard let canvas else { return false }
        consumedHeaderClick = false
        if isHeader, !isResize, event.modifierFlags.contains(.shift) {
            if ids.isEmpty, let active = canvas.canvasState.lastActiveTileId { ids.insert(active) }
            if !ids.insert(tile.tile.id).inserted { ids.remove(tile.tile.id) }
            consumedHeaderClick = true
            canvas.window?.makeFirstResponder(canvas)
            refresh()
            return true
        }
        if isHeader, !isResize, ids.count > 1, ids.contains(tile.tile.id) {
            return begin(event: event, edge: nil, pressedTileId: tile.tile.id)
        }
        selectOnly(tile.tile.id)
        return false
    }

    @discardableResult
    func begin(event: NSEvent, edge: ResizeEdge?, pressedTileId: UUID? = nil) -> Bool {
        guard let canvas, gesture == nil, ids.count > 1,
              let snapshot = TileSelectionGeometry.Snapshot(tiles: selectedWorldTiles()),
              snapshot.frames.count == ids.count,
              canvas.beginGeometryEdit(edge == nil ? .moveTile : .resizeTile,
                                       tileIds: ids, includeAllZones: true) else { return false }
        consumedHeaderClick = false
        gesture = Gesture(snapshot: snapshot, start: event.locationInWindow,
                          zoom: canvas.viewport.zoom, edge: edge, pressedTileId: pressedTileId)
        canvas.window?.makeFirstResponder(canvas)
        return true
    }

    @discardableResult
    func mouseDragged(with event: NSEvent) -> Bool {
        if consumedHeaderClick { return true }
        guard var gesture, let canvas else { return false }
        let delta = CGSize(width: (event.locationInWindow.x - gesture.start.x) / gesture.zoom,
                           height: (gesture.start.y - event.locationInWindow.y) / gesture.zoom)
        // A click and tiny pointer jitter must not create a layout transaction.
        if !gesture.moved, hypot(delta.width, delta.height) * gesture.zoom < 3 { return true }
        if gesture.moved, delta == gesture.lastDelta { return true }
        gesture.moved = true
        gesture.lastDelta = delta
        self.gesture = gesture
        let frames: [UUID: TileFrame]?
        if let edge = gesture.edge {
            frames = gesture.snapshot.resized(byWorldDelta: delta, edge: edge)
        } else {
            frames = gesture.snapshot.translated(byWorldDelta: delta)
        }
        guard let frames else { cancel(); return true }
        worldFrames = Array(frames.values)
        guard canvas.applySelectionFrames(frames) else {
            cancel()
            return true
        }
        batchUpdates += 1
        return true
    }

    @discardableResult
    func mouseUp(with event: NSEvent) -> Bool {
        if consumedHeaderClick {
            consumedHeaderClick = false
            return true
        }
        guard gesture != nil, let canvas else { return false }
        // Include the final pointer coordinate even if AppKit coalesced its
        // matching drag event. All previews derive from the initial snapshot.
        _ = mouseDragged(with: event)
        guard let gesture else { return true }
        if !gesture.moved, let pressed = gesture.pressedTileId {
            resolveClick(on: pressed)
            return true
        }
        self.gesture = nil
        _ = canvas.commitGeometryEdit()
        refresh()
        return true
    }

    func cancel() {
        guard gesture != nil else { return }
        gesture = nil
        consumedHeaderClick = true
        canvas?.cancelGeometryEdit()
        refresh()
    }

    /// The app's pre-dispatch mouse-up monitor must not focus/reorder a member
    /// while this owner is still tracking a group or a Shift-toggle. A press on
    /// a member that never moved is a click, though: that tile alone, focused.
    func consumeFocusRouting(for event: NSEvent) -> Bool {
        if let gesture, !gesture.moved, let pressed = gesture.pressedTileId,
           hypot(event.locationInWindow.x - gesture.start.x, event.locationInWindow.y - gesture.start.y) < 3 {
            resolveClick(on: pressed)
            return false
        }
        if ownsPointer { return true }
        guard let canvas else { return false }
        if canvas.isPointerPanActive { return true }
        if !event.modifierFlags.contains(.shift), !canvas.pointerPanRequested(for: event) {
            selectOnly(canvas.tileId(at: canvas.convert(event.locationInWindow, from: nil)))
        }
        return false
    }

    /// Ends an unmoved member press as a click on that member. The tile's own
    /// mouse-up then has nothing left to do.
    private func resolveClick(on id: UUID) {
        gesture = nil
        canvas?.cancelGeometryEdit()
        consumedHeaderClick = true
        ids = [id]
        refresh()
    }

    private func selectedWorldTiles() -> [Tile] {
        guard let canvas else { return [] }
        let collapsed = Set(canvas.workspaceZonePlacementsForPersistence().filter(\.collapsed).map(\.zoneId))
        if ids.count == 1, let id = ids.first, var tile = canvas.tileRecord(for: id) {
            guard !(tile.zoneId.map { collapsed.contains($0) } ?? false) else { return [] }
            tile.frame = canvas.worldFrame(forTileFrame: tile.frame, tileId: id)
            return [tile]
        }
        return canvas.allTilesInWorldFrames().filter {
            ids.contains($0.id) && !($0.zoneId.map { collapsed.contains($0) } ?? false)
        }
    }

    func refresh() {
        guard canvas != nil else { return }
        if gesture != nil { updatePresentation(); return }
        guard !ids.isEmpty else {
            worldFrames = []
            overlay?.isHidden = true
            return
        }
        let tiles = selectedWorldTiles()
        ids.formIntersection(tiles.map(\.id))
        worldFrames = tiles.map(\.frame)
        updatePresentation()
    }

    /// A camera change touches selected rectangles only, never the tile index.
    func updatePresentation() {
        guard let canvas else { return }
        guard !worldFrames.isEmpty else {
            overlay?.isHidden = true
            return
        }
        if overlay == nil {
            let view = TileSelectionOverlay(selection: self)
            overlay = view
            canvas.addSubview(view, positioned: .above, relativeTo: nil)
        }
        guard let overlay else { return }
        if overlay.frame != canvas.bounds { overlay.frame = canvas.bounds }
        overlay.rects = worldFrames.map { CanvasEngine.tileScreenFrame($0, viewport: canvas.viewport) }
        overlay.isHidden = false
        overlay.needsDisplay = true
        canvas.window?.invalidateCursorRects(for: overlay)
    }

    var qaOverlay: TileSelectionOverlay? { overlay }
}

/// One viewport-sized overlay, regardless of selection spread. Only handles
/// hit-test: native tile bodies and title controls remain interactive.
@MainActor
final class TileSelectionOverlay: NSView {
    weak var selection: CanvasTileSelection?
    var rects: [CGRect] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(selection: CanvasTileSelection) {
        self.selection = selection
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var groupRect: CGRect { rects.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -5, dy: -5) }
    var handles: [(ResizeEdge, CGRect)] {
        let r = groupRect
        guard rects.count > 1, !r.isNull, !r.isInfinite else { return [] }
        let positions: [(ResizeEdge, CGPoint)] = [(.topLeft, CGPoint(x: r.minX, y: r.minY)),
                (.top, CGPoint(x: r.midX, y: r.minY)),
                (.topRight, CGPoint(x: r.maxX, y: r.minY)),
                (.right, CGPoint(x: r.maxX, y: r.midY)),
                (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)),
                (.bottom, CGPoint(x: r.midX, y: r.maxY)),
                (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)),
                (.left, CGPoint(x: r.minX, y: r.midY))]
        return positions.map { ($0.0, CGRect(x: $0.1.x - 4, y: $0.1.y - 4, width: 8, height: 8)) }
    }
    func edge(at point: NSPoint) -> ResizeEdge? {
        handles.first { $0.1.insetBy(dx: -3, dy: -3).contains(point) }?.0
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let canvas = selection?.canvas else { return nil }
        if let event = NSApp.currentEvent, canvas.pointerPanRequested(for: event) { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return edge(at: local) == nil ? nil : self
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
        for rect in rects where rect.insetBy(dx: -3, dy: -3).intersects(dirtyRect) {
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 8, yRadius: 8)
            outline.lineWidth = FocusBorderOverlayView.lineWidth
            outline.stroke()
        }
        if rects.count > 1 {
            let path = NSBezierPath(rect: groupRect)
            path.lineWidth = FocusBorderOverlayView.lineWidth
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.stroke()
        }
        for (_, rect) in handles {
            NSColor.windowBackgroundColor.setFill()
            let handle = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            handle.lineWidth = FocusBorderOverlayView.lineWidth
            handle.fill()
            NSColor.controlAccentColor.setStroke()
            handle.stroke()
        }
    }
    override func resetCursorRects() {
        for (edge, rect) in handles {
            let cursor: NSCursor = (edge == .left || edge == .right) ? .resizeLeftRight : .resizeUpDown
            addCursorRect(rect.insetBy(dx: -3, dy: -3), cursor: cursor)
        }
    }
    override func mouseDown(with event: NSEvent) {
        selection?.preparePointerDown()
        guard let edge = edge(at: convert(event.locationInWindow, from: nil)) else { return }
        _ = selection?.begin(event: event, edge: edge)
    }
    override func mouseDragged(with event: NSEvent) { _ = selection?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { _ = selection?.mouseUp(with: event) }
    override func cancelOperation(_ sender: Any?) { selection?.canvas?.cancelOperation(sender) }
}
