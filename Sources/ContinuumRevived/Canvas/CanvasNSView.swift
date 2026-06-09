import AppKit
import ContinuumRevivedCore
import Foundation

/// Top-level canvas view: hosts tile subviews, owns the viewport, translates
/// world-space tile frames into AppKit subview frames, and routes pan/zoom
/// gestures to the underlying viewport. Flipped so the y-axis matches the
/// world-space convention (positive y = down).
@MainActor
final class CanvasNSView: NSView {
    weak var delegate: CanvasNSViewDelegate?
    var onFileURLDrop: ((String, CGPoint) -> Void)?
    /// Single-point hook for the app's tile-delete orchestrator. The canvas
    /// wires every installed tile's `onClose` to call this, so the app sets
    /// this once at startup rather than at every TileSpawner install site.
    var onTileCloseRequested: ((UUID) -> Void)?

    private(set) var canvasState: CanvasState
    private var tileViews: [UUID: TileNSView] = [:]
    private var emptyStateView: CanvasEmptyStateNSView?
    private var emptyStateActions: CanvasEmptyStateActions?
    private(set) var emptyStateInstalled = false

    private var spaceHeld = false
    private var spaceDragLastWindowPoint: CGPoint = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(canvasState: CanvasState) {
        self.canvasState = canvasState
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        registerForDraggedTypes([.fileURL])
        updateEmptyStateVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Tile management

    func install(tileView: TileNSView, for tile: Tile) {
        // Replacing an existing tile (e.g. restart placeholder → live terminal)
        // must remove the old NSView; otherwise the prior view stays on top
        // of the new one and intercepts hits.
        if let existing = tileViews[tile.id] {
            existing.removeFromSuperview()
        }
        tileViews[tile.id] = tileView
        tileView.canvas = self
        let tileId = tile.id
        tileView.onClose = { [weak self] in
            self?.onTileCloseRequested?(tileId)
        }
        addSubview(tileView)
        layoutTile(tile)
        if let idx = canvasState.tiles.firstIndex(where: { $0.id == tile.id }) {
            canvasState.tiles[idx] = tile
        } else {
            canvasState.tiles.append(tile)
        }
        updateEmptyStateVisibility()
    }

    func configureEmptyStateActions(_ actions: CanvasEmptyStateActions) {
        emptyStateActions = actions
        emptyStateView?.actions = actions
    }

    /// Returns the NSView currently registered for `tileId`, or nil. Intended
    /// for tests / smoke-test assertions that need to inspect tile-view kind
    /// (e.g. checking that a runtime-exit handler swapped to a placeholder).
    /// Callers must NOT retain the returned reference — the canvas may swap
    /// the underlying view at any time and a cached pointer will go stale.
    func tileView(for tileId: UUID) -> TileNSView? {
        tileViews[tileId]
    }

    /// Returns the topmost tile id under `pointInCanvas` (canvas-local coords),
    /// or nil if the point is on the canvas background. Used by the
    /// window-level focus monitor to bring tiles forward on body clicks even
    /// when the click is consumed by content children.
    func tileId(at pointInCanvas: NSPoint) -> UUID? {
        // canvasState.tiles is z-ordered front-last; iterate in reverse so the
        // topmost hit wins.
        for tile in canvasState.tiles.reversed() {
            guard let view = tileViews[tile.id] else { continue }
            if view.frame.contains(pointInCanvas) {
                return tile.id
            }
        }
        return nil
    }

    /// Remove a tile from the canvas: drops the NSView, the dictionary entry,
    /// and the model-side tile. Per-runtime cleanup (terminate PTY, kill
    /// WKWebView, flush note save, purge descriptor) is the caller's
    /// responsibility — `removeTile` is the canvas-side teardown only.
    func removeTile(id: UUID) {
        if let view = tileViews[id] {
            view.removeFromSuperview()
            tileViews.removeValue(forKey: id)
        }
        canvasState.tiles.removeAll { $0.id == id }
        if canvasState.lastActiveTileId == id {
            canvasState.lastActiveTileId = nil
        }
        updateEmptyStateVisibility()
        delegate?.canvasDidChange(self)
    }

    func updateTile(_ tile: Tile) {
        guard let idx = canvasState.tiles.firstIndex(where: { $0.id == tile.id }) else { return }
        canvasState.tiles[idx] = tile
        layoutTile(tile)
        delegate?.canvasDidChange(self)
    }

    func markActive(tileId: UUID) {
        canvasState.lastActiveTileId = tileId
        delegate?.canvasDidChange(self)
    }

    func bringToFront(tileId: UUID) {
        canvasState.tiles = CanvasEngine.bringToFront(tileId: tileId, in: canvasState.tiles)
        canvasState.lastActiveTileId = tileId
        // Reorder Subviews: newest-on-top
        if let view = tileViews[tileId] {
            view.removeFromSuperview()
            addSubview(view)
        }
        for tile in canvasState.tiles {
            tileViews[tile.id]?.tile = tile
        }
        delegate?.canvasDidChange(self)
    }

    func setViewport(_ viewport: CanvasViewport) {
        canvasState.viewport = viewport
        layoutAllTiles()
        delegate?.canvasDidChange(self)
    }

    var viewport: CanvasViewport { canvasState.viewport }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutAllTiles()
        layoutEmptyState()
    }

    private func layoutAllTiles() {
        for tile in canvasState.tiles {
            layoutTile(tile)
        }
    }

    private func layoutTile(_ tile: Tile) {
        guard let view = tileViews[tile.id] else { return }
        let rect = CanvasEngine.tileScreenFrame(tile.frame, viewport: canvasState.viewport)
        view.frame = rect
        view.tile = tile
    }

    private func updateEmptyStateVisibility() {
        if canvasState.tiles.isEmpty {
            installEmptyStateIfNeeded()
        } else {
            uninstallEmptyStateIfNeeded()
        }
    }

    private func installEmptyStateIfNeeded() {
        guard emptyStateView == nil else { return }
        let view = CanvasEmptyStateNSView(actions: emptyStateActions)
        emptyStateView = view
        addSubview(view, positioned: .above, relativeTo: nil)
        emptyStateInstalled = true
        layoutEmptyState()
    }

    private func uninstallEmptyStateIfNeeded() {
        emptyStateView?.removeFromSuperview()
        emptyStateView = nil
        emptyStateInstalled = false
    }

    private func layoutEmptyState() {
        emptyStateView?.frame = bounds
    }

    // MARK: - Pan / zoom gestures

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let cursor = convert(event.locationInWindow, from: nil)
            // Roughly +/- 10% per logical line of scroll. Smooth, non-linear.
            let factor = exp(event.scrollingDeltaY * 0.02)
            let next = CanvasEngine.zoom(canvasState.viewport, by: factor, anchorScreen: cursor)
            setViewport(next)
        } else {
            var dx = event.scrollingDeltaX
            var dy = event.scrollingDeltaY
            if event.hasPreciseScrollingDeltas {
                dx *= 1
                dy *= 1
            } else {
                dx *= 16
                dy *= 16
            }
            var v = canvasState.viewport
            v.x -= Double(dx) / v.zoom
            v.y -= Double(dy) / v.zoom
            setViewport(v)
        }
    }

    /// Trackpad pinch entry point. The window-level magnify monitor in
    /// ContinuumApp routes here so pinches over a tile body still zoom the
    /// canvas (the tile content has no zoom of its own to compete with).
    func handlePinch(_ event: NSEvent) {
        let cursor = convert(event.locationInWindow, from: nil)
        let factor = 1.0 + Double(event.magnification)
        guard factor > 0 else { return }
        let next = CanvasEngine.zoom(canvasState.viewport, by: factor, anchorScreen: cursor)
        setViewport(next)
    }

    override func mouseDown(with event: NSEvent) {
        if spaceHeld {
            // Space + drag pan: openHand → closedHand on press; pop on
            // mouseUp. Cursor stack restores cleanly even if the cursor
            // rect logic of subviews fights for control.
            NSCursor.closedHand.push()
            spaceDragLastWindowPoint = event.locationInWindow
            return
        }
        // Click on canvas background — deselect.
        canvasState.lastActiveTileId = nil
        delegate?.canvasDidChange(self)
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        if spaceHeld {
            let dx = event.locationInWindow.x - spaceDragLastWindowPoint.x
            let dy = event.locationInWindow.y - spaceDragLastWindowPoint.y
            spaceDragLastWindowPoint = event.locationInWindow
            var v = canvasState.viewport
            // Window y goes up, canvas y is flipped (down). Drag-down on the
            // trackpad/mouse should move the viewport down (revealing tiles
            // higher up), matching the trackpad scroll math in scrollWheel.
            v.x -= Double(dx) / v.zoom
            v.y += Double(dy) / v.zoom
            setViewport(v)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if spaceHeld {
            NSCursor.pop()
            return
        }
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Space (keyCode 49) starts hand-pan mode while held. We only see
        // this event when the canvas itself is first responder, so a Space
        // typed inside a note/terminal/url-bar still inserts a literal
        // space — no global hijack.
        if event.keyCode == 49 {
            if !spaceHeld {
                spaceHeld = true
                NSCursor.openHand.push()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, spaceHeld {
            spaceHeld = false
            NSCursor.pop()
            return
        }
        super.keyUp(with: event)
    }

    // MARK: - File drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFileURL(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = draggedFileURL(from: sender) else {
            return false
        }
        let screenPoint = convert(sender.draggingLocation, from: nil)
        let worldPoint = CanvasEngine.screenToWorld(screenPoint, viewport: canvasState.viewport)
        onFileURLDrop?(url.path, worldPoint)
        return true
    }

    private func draggedFileURL(from sender: NSDraggingInfo) -> URL? {
        guard let raw = sender.draggingPasteboard.string(forType: .fileURL) else {
            return nil
        }
        return URL(string: raw)
    }
}

@MainActor
protocol CanvasNSViewDelegate: AnyObject {
    func canvasDidChange(_ canvas: CanvasNSView)
}
