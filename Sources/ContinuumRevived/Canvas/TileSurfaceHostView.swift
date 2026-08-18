import AppKit
import ContinuumRevivedCore

/// A tile body that is one Array-owned `CALayer` carrying a baked surface.
///
/// This is Shape A's whole mechanism (`.plans/34` I15): a surfaced tile is an
/// ordinary `TileNSView` — chrome, close button, grab strip, resize edges, cursor
/// rects, focus adapter and z-order all unchanged — whose CONTENT VIEW is this.
/// Nothing about the camera, the world plane, or tile geometry moves.
///
/// It is **layer-hosting, not layer-backed**: Array assigns `layer` itself, so
/// AppKit does not own these contents and cannot invalidate them behind our back.
/// The consequence is that this view also owns the response to a backing-property
/// change, which is load-bearing — see `viewDidChangeBackingProperties`.
@MainActor
final class TileSurfaceHostView: NSView {
    /// Steps per octave for the layer's `contentsScale`, matching
    /// `TileNSView.chromeScaleStepsPerOctave` so a surface and the chrome above it
    /// change density at the same small number of boundaries rather than
    /// independently.
    private static let stepsPerOctave: Double = 4

    /// Readable so a tile can tell whether the host it already has is showing the
    /// surface it is about to be given, and skip rebuilding it. `CGImage` is a
    /// reference type, so identity is the right comparison.
    let surface: CGImage
    private let surfaceLayer = CALayer()

    /// Device pixels per world point the image actually carries. Read by the
    /// canvas to decide whether this surface is still sharp enough to show.
    let bakedScale: CGFloat

    private(set) var qaBackingCallbackCount = 0
    private(set) var qaContentsScaleChangeCount = 0

    init(surface: CGImage, bakedScale: CGFloat, backingScale: CGFloat) {
        self.surface = surface
        self.bakedScale = bakedScale
        super.init(frame: .zero)
        surfaceLayer.contents = surface
        surfaceLayer.contentsGravity = .resize
        surfaceLayer.contentsScale = Self.bucket(backingScale)
        // The bake is taken from a top-left-origin flipped view, so the layer has
        // to read it the same way round or every surfaced tile is upside down.
        surfaceLayer.isGeometryFlipped = true
        surfaceLayer.masksToBounds = true
        layer = surfaceLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Guarded: an unchanged frame assignment still marks the layer dirty, which
        // is the identity-write mistake `applyTileGeometry` already documents.
        if surfaceLayer.frame != bounds { surfaceLayer.frame = bounds }
    }

    /// **The `contentsScale` trap, and the reason this class exists.**
    ///
    /// AppKit sends this to every installed surface host on EVERY camera step —
    /// measured at exactly `hosts x steps` (1,500 for 25 tiles over 60 steps). The
    /// obvious implementation reads the view's effective scale (ancestor camera
    /// scale x backing scale) and re-derives the surface to match, which turns one
    /// camera step into one re-rasterisation per visible tile: a GREEN geometry
    /// counter over a RED gesture.
    ///
    /// So the owned policy follows only the DISPLAY's backing scale, which canvas
    /// zoom does not change, bucketed. A camera step therefore causes no scale
    /// change and no re-derivation at all; a real display change (1x <-> 2x, a
    /// window moved between monitors) still does, which is correct — that is a new
    /// resolution regime and the canvas re-bakes for it.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        qaBackingCallbackCount += 1
        let desired = Self.bucket(window?.backingScaleFactor ?? 2)
        guard abs(surfaceLayer.contentsScale - desired) > 0.0001 else { return }
        surfaceLayer.contentsScale = desired
        qaContentsScaleChangeCount += 1
        surfaceLayer.setNeedsDisplay()
    }

    /// Geometric and rounding DOWN, like `TileNSView.chromeScaleBucket`. Down
    /// matters: rounding up would claim a density the image does not carry.
    private static func bucket(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return 1 }
        let bucketed = pow(2, (log2(Double(scale)) * stepsPerOctave).rounded(.down) / stepsPerOctave)
        return bucketed.isFinite && bucketed > 0 ? CGFloat(bucketed) : scale
    }

    func qaResetCounters() {
        qaBackingCallbackCount = 0
        qaContentsScaleChangeCount = 0
    }
}
