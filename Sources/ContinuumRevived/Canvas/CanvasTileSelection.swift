import AppKit
import ContinuumRevivedCore

/// Ephemeral workspace selection. Keyboard focus continues to belong to one
/// surface. Native body events stay native; an all-agent group can hand its
/// header drag to the same reference-drop interaction as a single agent.
@MainActor
final class CanvasTileSelection {
    weak var canvas: CanvasNSView?
    private(set) var ids: Set<UUID> = []
    private var overlay: TileSelectionOverlay?
    private var consumedHeaderClick = false
    private var worldFrames: [(id: UUID, frame: TileFrame)] = []
    private let hover = SelectionHoverPresentation()
    private(set) var presentationFrames: [UUID: TileFrame] = [:]
    private struct Gesture {
        let snapshot: TileSelectionGeometry.Snapshot
        let start: NSPoint
        let zoom: Double
        let edge: ResizeEdge?
        /// The member whose title bar was pressed; nil for the group handles.
        let pressedTileId: UUID?
        var moved = false
        var lastDelta: CGSize = .zero
        var magneticTarget: MagneticPlacement.Target?
        var dropBounds: TileFrame?
        var referenceDrag: AgentReferenceDrag?
        var holdingReference = false
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
        if edge == nil, pressedTileId != nil {
            let views = canvas.tileViewsInVisualOrder.filter { ids.contains($0.tile.id) }
            let sources = views.compactMap { $0 as? ManagedAgentTileNSView }
            if sources.count == ids.count {
                gesture?.referenceDrag = AgentReferenceDrag(sources: sources, canvas: canvas)
            }
        }
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
        if gesture.moved, delta == gesture.lastDelta, gesture.referenceDrag == nil { return true }
        if !gesture.moved {
            _ = hover.apply(canvas: canvas, frames: worldFrames, enabled: false, animated: false)
            canvas.beginAutoLayoutGesture()
        }
        gesture.moved = true
        gesture.lastDelta = delta
        self.gesture = gesture
        if let referenceDrag = gesture.referenceDrag {
            let pointer = CanvasEngine.screenToWorld(canvas.convert(event.locationInWindow, from: nil), viewport: canvas.viewport)
            referenceDrag.setRecipient(referenceDrag.recipient(atWorld: pointer, event: event))
            if referenceDrag.recipient != nil {
                gesture.magneticTarget = nil
                gesture.dropBounds = nil
                if !gesture.holdingReference {
                    gesture.holdingReference = true
                    worldFrames = gesture.snapshot.frames.map { ($0.key, $0.value) }
                    self.gesture = gesture
                    guard canvas.restoreGeometryEditPreview() else { cancel(); return true }
                }
                self.gesture = gesture
                canvas.hideDragGhost()
                referenceDrag.showCard(atWindowPoint: event.locationInWindow, in: canvas)
                updatePresentation()
                return true
            }
            gesture.holdingReference = false
            self.gesture = gesture
        }
        canvas.setAutoLayoutMovePointer(windowPoint: event.locationInWindow,
                                        preferSwap: event.modifierFlags.contains(.option))
        let frames: [UUID: TileFrame]?
        if let edge = gesture.edge {
            frames = gesture.snapshot.resized(byWorldDelta: delta, edge: edge)
        } else {
            var free = gesture.snapshot.bounds
            free.x += delta.width
            free.y += delta.height
            let placement = canvas.selectionMagneticPlacement(free: free, excluding: ids,
                                                              previous: gesture.magneticTarget)
            gesture.magneticTarget = placement.target
            frames = gesture.snapshot.translated(byWorldDelta: CGSize(
                width: placement.frame.x - gesture.snapshot.bounds.x,
                height: placement.frame.y - gesture.snapshot.bounds.y))
        }
        self.gesture = gesture
        guard let frames else { cancel(); return true }
        worldFrames = frames.map { ($0.key, $0.value) }
        guard canvas.applySelectionFrames(frames) else {
            cancel()
            return true
        }
        if gesture.edge == nil {
            gesture.dropBounds = canvas.autoLayoutLatchedSlot ?? gesture.magneticTarget?.frame
            if let target = gesture.dropBounds { canvas.showDragGhost(at: target) }
            else { canvas.hideDragGhost() }
            self.gesture = gesture
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
        if gesture.moved, let referenceDrag = gesture.referenceDrag {
            let pointer = CanvasEngine.screenToWorld(canvas.convert(event.locationInWindow, from: nil), viewport: canvas.viewport)
            if let recipient = referenceDrag.recipient(atWorld: pointer, event: event) {
                referenceDrag.end()
                self.gesture = nil
                canvas.hideDragGhost()
                _ = canvas.finishAutoLayoutGesture()
                canvas.cancelGeometryEdit()
                refresh()
                referenceDrag.commit(to: recipient)
                return true
            }
        }
        gesture.referenceDrag?.end()
        if gesture.moved, gesture.edge == nil {
            if let target = gesture.dropBounds,
               let frames = gesture.snapshot.translated(byWorldDelta: CGSize(
                width: target.x - gesture.snapshot.bounds.x,
                height: target.y - gesture.snapshot.bounds.y)) {
                worldFrames = frames.map { ($0.key, $0.value) }
                _ = canvas.applySelectionFrames(frames)
            }
            canvas.settleSelectionAfterMove(ids, honorSnap: gesture.dropBounds != nil)
        }
        canvas.hideDragGhost()
        _ = canvas.finishAutoLayoutGesture()
        self.gesture = nil
        _ = canvas.commitGeometryEdit()
        refresh()
        return true
    }

    func cancel() {
        guard let gesture else { return }
        gesture.referenceDrag?.end()
        self.gesture = nil
        consumedHeaderClick = true
        canvas?.hideDragGhost()
        _ = canvas?.finishAutoLayoutGesture()
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
        gesture?.referenceDrag?.end()
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
            updatePresentation()
            return
        }
        let tiles = selectedWorldTiles()
        ids.formIntersection(tiles.map(\.id))
        worldFrames = tiles.map { ($0.id, $0.frame) }
        updatePresentation()
    }

    /// A camera change touches selected rectangles only, never the tile index.
    func updatePresentation() {
        guard let canvas else { return }
        let hovering = worldFrames.count > 1 && gesture?.moved != true
        let presented = hover.apply(canvas: canvas, frames: worldFrames, enabled: hovering)
        presentationFrames = hovering ? Dictionary(uniqueKeysWithValues: presented.map { ($0.id, $0.frame) }) : [:]
        // Resolve all outline owners together, even after clearing selection:
        // the focus/attention overlays must recover their ordinary clearance.
        let resolved = canvas.resolveTileOutlineGeometry(selected: presented.count > 1 ? presented : [])
        // One tile draws nothing: the focus ants already mark it.
        guard worldFrames.count > 1 else {
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
        overlay.rects = presented.map { CanvasEngine.tileScreenFrame($0.frame, viewport: canvas.viewport) }
        overlay.outlines = worldFrames.compactMap { resolved[$0.id] }
        overlay.ringed = worldFrames.map { !canvas.tileWearsRing($0.id) }
        overlay.style = canvas.focusRingStyle
        overlay.tileScale = CGFloat(canvas.viewport.zoom)
        overlay.isHidden = false
        overlay.needsDisplay = true
        // Invalidating cursor rects makes AppKit walk the WHOLE window's view tree
        // (`_invalidateCursorRectsForViewsWithNoTrackingAreas`, ~2.5 ms a step in a
        // live 18-tile session). The handles are not usable mid-gesture, so a driver
        // step defers it and the settle edge does it once.
        if canvas.isCameraDriverStepInFlight {
            qaDeferredCursorInvalidations += 1
        } else {
            canvas.window?.invalidateCursorRects(for: overlay)
            qaCursorInvalidations += 1
        }
    }

    private(set) var qaCursorInvalidations = 0
    private(set) var qaDeferredCursorInvalidations = 0

    var qaOverlay: TileSelectionOverlay? { overlay }
}

/// One viewport-sized overlay, regardless of selection spread. Only handles
/// hit-test: native tile bodies and title controls remain interactive.
///
/// It draws nothing for one tile: the focus ants already mark it. A group's
/// members get rings in the ants' own colour, gap, radius and dash, except a
/// member that already wears the ants or the attention ring.
@MainActor
final class TileSelectionOverlay: NSView {
    weak var selection: CanvasTileSelection?
    var rects: [CGRect] = []
    var outlines: [TileOutlineGeometry.Result] = []
    /// Parallel to `rects`: false where the tile already wears a ring.
    var ringed: [Bool] = []
    var style: (color: NSColor, gap: CGFloat) = (.controlAccentColor, CGFloat(FocusBorderConfig.defaultGap))
    var tileScale: CGFloat = 1
    /// How far the group frame sits outside the member rings.
    static let groupInset: CGFloat = 6
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(selection: CanvasTileSelection) {
        self.selection = selection
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var groupRect: CGRect {
        rects.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -(style.gap + Self.groupInset), dy: -(style.gap + Self.groupInset))
    }
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
    /// The full stroke bounds actually painted for the non-focus members.
    var qaMemberRingBounds: [CGRect] {
        zip(outlines, ringed).filter { $0.1 }.map { $0.0.rect }
    }
    private func ringPath(_ outline: TileOutlineGeometry.Result) -> NSBezierPath {
        let width = FocusBorderOverlayView.lineWidth
        let radius = FocusBorderOverlayView.ringRadius(tileScale: tileScale, gap: style.gap)
        return NSBezierPath(roundedRect: outline.rect.insetBy(dx: width / 2, dy: width / 2),
                            xRadius: radius, yRadius: radius)
    }

    /// The same clipping area is used by drawing and the overlap witness.
    private func visibleArea(_ outline: TileOutlineGeometry.Result) -> CGPath {
        var area = CGPath(rect: outline.rect, transform: nil)
        for occluder in outline.occluders {
            area = area.subtracting(CGPath(rect: occluder, transform: nil))
        }
        return area
    }

    var qaVisibleStrokePaths: [CGPath] {
        guard !isHidden else { return [] }
        return zip(outlines, ringed).filter { $0.1 && !$0.0.rect.isEmpty }.map { outline, _ in
            ringPath(outline).cgPath.copy(strokingWithWidth: FocusBorderOverlayView.lineWidth,
                                         lineCap: .butt, lineJoin: .miter, miterLimit: 10)
                .intersection(visibleArea(outline))
        }
    }

    /// QA: how many member rings the overlay draws right now.
    var qaDrawnRingCount: Int { isHidden || rects.count < 2 ? 0 : ringed.filter { $0 }.count }
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
        guard rects.count > 1 else { return }
        let lineWidth = FocusBorderOverlayView.lineWidth
        let dash = FocusBorderOverlayView.dashPattern.map { CGFloat($0.doubleValue) }
        let ringRadius = FocusBorderOverlayView.ringRadius(tileScale: tileScale, gap: style.gap)
        style.color.setStroke()
        for (outline, ringed) in zip(outlines, ringed) where ringed {
            guard !outline.rect.isEmpty, outline.rect.intersects(dirtyRect),
                  let context = NSGraphicsContext.current?.cgContext else { continue }
            context.saveGState()
            context.addPath(visibleArea(outline))
            context.clip()
            let path = ringPath(outline)
            path.lineWidth = lineWidth
            path.setLineDash(dash, count: dash.count, phase: 0)
            path.stroke()
            context.restoreGState()
        }
        let groupRadius = ringRadius == 0 ? 0 : ringRadius + Self.groupInset
        let group = NSBezierPath(roundedRect: groupRect.insetBy(dx: 0.5, dy: 0.5), xRadius: groupRadius, yRadius: groupRadius)
        group.lineWidth = 1
        style.color.withAlphaComponent(style.color.alphaComponent * 0.5).setStroke()
        group.stroke()
        for (_, rect) in handles {
            let handle = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            handle.lineWidth = 1
            NSColor.windowBackgroundColor.setFill()
            handle.fill()
            style.color.withAlphaComponent(1).setStroke()
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
