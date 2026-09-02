import AppKit

/// The world plane: a fixed clip whose content view carries the camera.
///
/// `CanvasNSView` used to be a single view holding both world-attached content
/// (tiles, zone chrome) and screen-fixed overlays (nav mode, focus border, HUDs),
/// which forced a camera step to re-derive and write a screen frame per tile.
/// A zoom therefore resized every tile view, `setFrameSize` scaled `bounds` away,
/// the logical size had to be written back, and AppKit re-laid out every tile
/// subtree at a width it never rendered — 48 ms/step against an 8.3 ms budget.
/// See [performance-budgets.md](../../../docs/internals/performance-budgets.md).
///
/// One view does both jobs. Its `frame` is the fixed viewport rect in canvas
/// coordinates, and its `bounds` carries the camera — origin is the pan, size is
/// `viewportSize / zoom` for the zoom. Tiles and zone chrome are its children at
/// **world** frames, which a camera step never touches. Because the bounds ARE
/// the visible world region, clipping to them is exactly viewport clipping.
///
/// A child at world point `P` lands at `(P - bounds.origin) * zoom` — which is
/// `CanvasEngine`'s transform exactly. Both spaces are flipped, so no mirroring
/// term appears. `NSClipView` scrolls by the same means. Nothing here transforms
/// an AppKit-owned backing layer, which Apple documents as unsupported because
/// the layer and the view desynchronize.
///
/// **A camera write costs a subtree traversal, and no arrangement avoids it.**
/// Measured on `canvas.stress` (48 real agent tiles, 6 zones, zoom 0.35), where
/// the fixture forces a synchronous `layoutSubtreeIfNeeded` after every step:
///
/// | camera write | ms/step |
/// |---|---|
/// | none at all (deliberately broken) | 0.001 |
/// | `setBoundsOrigin` on this view | 7.2 |
/// | `setFrameOrigin` on a nested content view | 8.8 |
/// | `setBoundsOrigin` on a nested content view | 8.2 |
///
/// So the traversal — not the write — is the cost. Translating by frame origin
/// is slightly worse than bounds origin, and adding a second view level costs
/// another ~1 ms of traversal, which is why this is one view rather than a
/// clip/document pair.
/// A profile of the bounds version puts **131 of 5,588 samples (2.3%) in the
/// camera itself**; the rest is AppKit recursing `_layoutSubtreeWithOldSize:`
/// through the tile trees with no Array code at the leaves. The bounds form is
/// kept because it is both faster and simpler. Reducing that traversal is a
/// property of how deep and how numerous the tile view trees are — Slice 5's
/// presentation working set — not of the camera.
///
/// Two properties are load-bearing rather than incidental:
///
/// - **`autoresizesSubviews = false`.** A zoom changes this view's bounds size, and AppKit's default response is to resize subviews through their
///   autoresizing masks — reintroducing exactly the per-tile frame writes this
///   design exists to remove. (Not the failed experiment in
///   performance-budgets.md: that one suppressed autoresizing while still
///   resizing every tile's frame. Here no tile frame ever changes.)
/// - **`clipsToBounds = true`.** The viewport boundary is explicit rather than
///   left to the window. Clipping bounds drawing only: it does not bound layout,
///   timers or semantic work, so it is not culling.
final class CanvasWorldPlaneView: NSView {
    override var isFlipped: Bool { true }

    /// QA: the exact write that triggers AppKit's backing-properties cascade.
    /// Kept separate from `applyCamera`'s aggregate return so a probe cannot
    /// confuse a harmless bounds-origin pan with a bounds-size zoom.
    private(set) var qaBoundsSizeWriteCount = 0
    func qaResetBoundsSizeWriteCount() { qaBoundsSizeWriteCount = 0 }

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        autoresizesSubviews = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A transparent container: a click on a tile must reach the tile, and a click
    /// on empty world must fall through to the canvas so marquee selection,
    /// pointer pan and background clicks keep working. `NSView`'s default would
    /// claim every in-bounds point for the plane itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// Point the camera. Returns how many geometry writes reached AppKit, which is
    /// what `canvas.camera-slope` counts as `cameraMutations`.
    ///
    /// Each component is written only when it changed, and compared with a
    /// tolerance rather than `!=`: AppKit keeps the bounds/frame scale and
    /// recomputes sizes from it, so at a non-integral zoom an exact comparison
    /// never matches and a "skip unchanged writes" guard writes every time —
    /// worse than no guard at all. See performance-budgets.md, "The
    /// float-tolerance trap".
    @discardableResult
    func applyCamera(viewportSize: CGSize, worldOrigin: CGPoint, zoom: Double) -> Int {
        let safeZoom = zoom > 0 ? zoom : 1
        var writes = 0

        // ZOOM: bounds size sets the scale, since frameSize / boundsSize == zoom.
        let desiredBounds = CGSize(width: viewportSize.width / safeZoom,
                                   height: viewportSize.height / safeZoom)
        if !Self.nearlyEqual(bounds.size.width, desiredBounds.width)
            || !Self.nearlyEqual(bounds.size.height, desiredBounds.height) {
            setBoundsSize(desiredBounds)
            qaBoundsSizeWriteCount += 1
            writes += 1
        }
        // PAN: the bounds origin is the world point at the viewport's top-left.
        if !Self.nearlyEqual(bounds.origin.x, worldOrigin.x)
            || !Self.nearlyEqual(bounds.origin.y, worldOrigin.y) {
            setBoundsOrigin(worldOrigin)
            writes += 1
        }
        return writes
    }

    private static func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    // MARK: - Visibility index

    /// A uniform grid over the plane's TILE children, so answering "which tiles
    /// does the camera see?" costs O(visible) instead of O(installed).
    ///
    /// This is WS3's measured fix, not a speculative one.
    /// `CanvasNSView.visibleTileViews` used to `compactMap` every world-plane
    /// subview and rectangle-test it on EVERY camera commit. The chrome refresh
    /// it feeds was already visible-only (`canvas.magnify-slope` pins that at a
    /// zero slope), so the discovery pass was the last thing on the camera's hot
    /// path whose cost grew with tiles the user cannot see:
    /// `--canvas-visibility-index-check` counted 128 candidate visits per commit
    /// at 128 installed with 12 visible, and 16 at 16 installed — a slope of
    /// exactly 1 per extra parked tile.
    ///
    /// The index is rebuilt lazily and only when the world changed shape:
    /// a tile was installed, removed, moved or resized. A CAMERA step changes
    /// nothing here — the plane's bounds carry the camera and every tile frame is
    /// a world frame — so a whole gesture answers from one build at most.
    ///
    /// Cell size is a world constant rather than adaptive: tiles are hundreds of
    /// world units across, so a 1024-unit cell holds a handful, and a 1600x1000
    /// viewport at zoom 1 spans 4 cells. Zoomed far enough OUT the query rect
    /// covers more cells than a full scan would cost, so the query falls back to
    /// the brute-force walk above `maxCellsPerQuery` — at that zoom essentially
    /// every tile IS a candidate, so the fallback is the honest answer and not a
    /// hole in the invariant.
    static let visibilityCellSize: CGFloat = 1_024
    static let visibilityMaxCellsPerQuery = 4_096

    private struct VisibilityCell: Hashable {
        let column: Int
        let row: Int
    }

    private var visibilityCells: [VisibilityCell: [Int]] = [:]
    /// Index-ordered tiles, so a query can restore subview order without a
    /// second walk of `subviews`.
    private var visibilityTiles: [TileNSView] = []
    private var visibilityIndexIsDirty = true

    /// QA: how many tile views a visibility query actually examined. This is the
    /// number that must NOT grow when off-screen tiles are added.
    private(set) var qaVisibilityCandidateVisits = 0
    /// QA: how many times the grid was rebuilt (each rebuild is O(installed), so
    /// a per-camera-step rebuild would defeat the whole point).
    private(set) var qaVisibilityIndexRebuilds = 0
    /// QA: total queries, and how many of those took the zoomed-way-out fallback.
    private(set) var qaVisibilityQueryCount = 0
    private(set) var qaVisibilityBruteForceQueryCount = 0

    func qaResetVisibilityStats() {
        qaVisibilityCandidateVisits = 0
        qaVisibilityIndexRebuilds = 0
        qaVisibilityQueryCount = 0
        qaVisibilityBruteForceQueryCount = 0
    }

    /// The world changed shape. Called from `didAddSubview`/`willRemoveSubview`
    /// and from `TileNSView`'s frame primitives, which are the only ways a tile
    /// enters, leaves or moves within the plane.
    func invalidateVisibilityIndex() {
        visibilityIndexIsDirty = true
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        invalidateVisibilityIndex()
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        invalidateVisibilityIndex()
    }

    override func sortSubviews(
        _ compare: @convention(c) (NSView, NSView, UnsafeMutableRawPointer?) -> ComparisonResult,
        context: UnsafeMutableRawPointer?
    ) {
        super.sortSubviews(compare, context: context)
        invalidateVisibilityIndex()
    }

    private func rebuildVisibilityIndexIfNeeded() {
        guard visibilityIndexIsDirty else { return }
        visibilityIndexIsDirty = false
        qaVisibilityIndexRebuilds += 1
        visibilityCells.removeAll(keepingCapacity: true)
        visibilityTiles.removeAll(keepingCapacity: true)
        let cell = Self.visibilityCellSize
        for subview in subviews {
            guard let tile = subview as? TileNSView else { continue }
            let ordinal = visibilityTiles.count
            visibilityTiles.append(tile)
            let frame = tile.frame
            let minColumn = Int((frame.minX / cell).rounded(.down))
            let maxColumn = Int((frame.maxX / cell).rounded(.down))
            let minRow = Int((frame.minY / cell).rounded(.down))
            let maxRow = Int((frame.maxY / cell).rounded(.down))
            for column in minColumn...max(minColumn, maxColumn) {
                for row in minRow...max(minRow, maxRow) {
                    visibilityCells[VisibilityCell(column: column, row: row), default: []].append(ordinal)
                }
            }
        }
    }

    /// Tile children intersecting `rect` (a WORLD rect), in subview order.
    func tileViews(intersecting rect: CGRect) -> [TileNSView] {
        qaVisibilityQueryCount += 1
        rebuildVisibilityIndexIfNeeded()
        let cell = Self.visibilityCellSize
        let minColumn = Int((rect.minX / cell).rounded(.down))
        let maxColumn = Int((rect.maxX / cell).rounded(.down))
        let minRow = Int((rect.minY / cell).rounded(.down))
        let maxRow = Int((rect.maxY / cell).rounded(.down))
        let columns = maxColumn - minColumn + 1
        let rows = maxRow - minRow + 1
        guard columns > 0, rows > 0,
              columns.multipliedReportingOverflow(by: rows).overflow == false,
              columns * rows <= Self.visibilityMaxCellsPerQuery else {
            qaVisibilityBruteForceQueryCount += 1
            var result: [TileNSView] = []
            for tile in visibilityTiles {
                qaVisibilityCandidateVisits += 1
                if tile.frame.intersects(rect) { result.append(tile) }
            }
            return result
        }

        var seen = Set<Int>()
        var ordinals: [Int] = []
        for column in minColumn...maxColumn {
            for row in minRow...maxRow {
                guard let bucket = visibilityCells[VisibilityCell(column: column, row: row)] else { continue }
                for ordinal in bucket where seen.insert(ordinal).inserted {
                    qaVisibilityCandidateVisits += 1
                    if visibilityTiles[ordinal].frame.intersects(rect) { ordinals.append(ordinal) }
                }
            }
        }
        return ordinals.sorted().map { visibilityTiles[$0] }
    }

    /// QA anti-teeth: the index must answer EXACTLY what a full subview walk
    /// answers. Deliberately O(installed) and never called on the camera path.
    func qaBruteForceTileViews(intersecting rect: CGRect) -> [TileNSView] {
        subviews.compactMap { subview in
            guard let tile = subview as? TileNSView, tile.frame.intersects(rect) else { return nil }
            return tile
        }
    }
}
