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

    private(set) var canvasState: CanvasState
    private var tileViews: [UUID: TileNSView] = [:]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(canvasState: CanvasState) {
        self.canvasState = canvasState
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
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
        addSubview(tileView)
        layoutTile(tile)
        if let idx = canvasState.tiles.firstIndex(where: { $0.id == tile.id }) {
            canvasState.tiles[idx] = tile
        } else {
            canvasState.tiles.append(tile)
        }
        reorderTileSubviewsByZIndex()
    }

    /// Returns the NSView currently registered for `tileId`, or nil. Intended
    /// for tests / smoke-test assertions that need to inspect tile-view kind
    /// (e.g. checking that a runtime-exit handler swapped to a placeholder).
    /// Callers must NOT retain the returned reference — the canvas may swap
    /// the underlying view at any time and a cached pointer will go stale.
    func tileView(for tileId: UUID) -> TileNSView? {
        tileViews[tileId]
    }

    func updateTile(_ tile: Tile) {
        guard let idx = canvasState.tiles.firstIndex(where: { $0.id == tile.id }) else { return }
        canvasState.tiles[idx] = tile
        layoutTile(tile)
        delegate?.canvasDidChange(self)
    }

    func bringToFront(tileId: UUID) {
        canvasState.tiles = CanvasEngine.bringToFront(tileId: tileId, in: canvasState.tiles)
        canvasState.lastActiveTileId = tileId
        for tile in canvasState.tiles {
            tileViews[tile.id]?.tile = tile
        }
        reorderTileSubviewsByZIndex()
        delegate?.canvasDidChange(self)
    }

    func setViewport(_ viewport: CanvasViewport) {
        canvasState.viewport = viewport
        layoutAllTiles()
        delegate?.canvasDidChange(self)
    }

    /// Returns the topmost tile id at a screen-space point according to the
    /// semantic canvas model, not AppKit subview insertion order.
    func tileId(at screenPoint: CGPoint) -> UUID? {
        CanvasEngine.hitTest(screenPoint: screenPoint, viewport: canvasState.viewport, tiles: canvasState.tiles)?.id
    }

    var viewport: CanvasViewport { canvasState.viewport }

    private func reorderTileSubviewsByZIndex() {
        let modelOrder = Dictionary(uniqueKeysWithValues: canvasState.tiles.enumerated().map { ($0.element.id, $0.offset) })
        let orderedViews = tileViews.values.sorted { lhs, rhs in
            let lhsZ = lhs.tile.zIndex
            let rhsZ = rhs.tile.zIndex
            if lhsZ != rhsZ { return lhsZ < rhsZ }
            return (modelOrder[lhs.tile.id] ?? Int.max) < (modelOrder[rhs.tile.id] ?? Int.max)
        }
        for view in orderedViews {
            view.removeFromSuperview()
            addSubview(view)
        }
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutAllTiles()
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

    override func mouseDown(with event: NSEvent) {
        // Click on canvas background — deselect.
        canvasState.lastActiveTileId = nil
        delegate?.canvasDidChange(self)
        window?.makeFirstResponder(self)
    }

    static func runZIndexRelaunchHitTestSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)

            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let midId = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!
        let topId = UUID(uuidString: "00000000-0000-0000-0000-000000000199")!
        let lowId = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let overlap = TileFrame(x: 100, y: 100, width: 300, height: 220)
        let seededTiles = [
            Tile(id: midId, kind: .note, title: "MID_FIRST", frame: overlap, zIndex: 5, runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: topId, kind: .note, title: "TOP_MIDDLE", frame: overlap, zIndex: 99, runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: lowId, kind: .note, title: "LOW_LAST", frame: overlap, zIndex: 1, runtimeRef: nil, metadata: TileMetadata())
        ]
        let viewport = CanvasViewport(x: 0, y: 0, zoom: 1)
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: viewport, tiles: seededTiles, groups: [], lastActiveTileId: nil))

        for tile in seededTiles {
            canvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
        }
        // Replacement install must not let the replaced/later low-z view jump above max z.
        canvas.install(tileView: DescriptorTileNSView(tile: seededTiles[2]), for: seededTiles[2])

        let modelOrder = canvas.canvasState.tiles.map(\.id)
        let visualOrder = canvas.subviews.compactMap { ($0 as? TileNSView)?.tile.id }
        let visualTopId = visualOrder.last
        let hitPoint = CGPoint(x: 150, y: 150)
        let semanticHitId = CanvasEngine.hitTest(screenPoint: hitPoint, viewport: viewport, tiles: canvas.canvasState.tiles)?.id
        let canvasHitId = canvas.tileId(at: hitPoint)

        try expect(modelOrder == seededTiles.map(\.id), "self-check must preserve seeded model array order")
        try expect(visualTopId == topId, "top AppKit subview should be max zIndex tile")
        try expect(semanticHitId == topId, "CanvasEngine hit-test should return max zIndex tile")
        try expect(canvasHitId == topId, "CanvasNSView tileId(at:) should return max zIndex tile")

        let manifest: [String: Any] = [
            "check": "zindex-relaunch-hit-test",
            "arrayOrder": seededTiles.map { $0.id.uuidString },
            "zIndices": Dictionary(uniqueKeysWithValues: seededTiles.map { ($0.id.uuidString, $0.zIndex) }),
            "visualSubviewOrder": visualOrder.map { $0.uuidString },
            "hitPoint": ["x": hitPoint.x, "y": hitPoint.y],
            "expectedTopId": topId.uuidString,
            "actualVisualTopId": visualTopId?.uuidString as Any,
            "actualCanvasEngineHitId": semanticHitId?.uuidString as Any,
            "actualCanvasViewHitId": canvasHitId?.uuidString as Any
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("zindex-relaunch", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }
}

@MainActor
protocol CanvasNSViewDelegate: AnyObject {
    func canvasDidChange(_ canvas: CanvasNSView)
}
