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

}
