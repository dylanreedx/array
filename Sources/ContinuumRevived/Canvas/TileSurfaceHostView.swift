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

    // **No `layout()` override, deliberately — and this is load-bearing.**
    //
    // `surfaceLayer` is this view's ROOT layer, so its frame lives in the
    // SUPERLAYER's coordinate space and AppKit already maintains it from the
    // view's frame. The override that used to live here wrote `surfaceLayer.frame
    // = bounds`, whose origin is always `(0, 0)`, and a surfaced tile's host is
    // framed at `(0, titleBarHeight)` inside its tile — so every layout pass over
    // a surfaced tile shoved the baked picture UP by the full title-bar height,
    // 24 pt, while the native body drew at the correct offset. That was the
    // "the whole tile shifts" half of the blur->sharp transition report.
    //
    // Measured (`.plans/39`): correct at `(0, 24, 420, 276)` in the turn the swap
    // happened — AppKit's sync, before any layout pass — then `(0, 0, 420, 276)`
    // after one pump, and NOT on every tile in the same pass, which is why the
    // shift looked intermittent. Witnessed by
    // `checkTheSurfaceLandsExactlyWhereTheBodyDrew`.

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

    /// The hosted layer's own geometry and animation state. Read by witnesses:
    /// this layer is the view's ROOT layer and Array owns it, so nothing in AppKit
    /// disables implicit animations on it and nothing else asserts where it sits.
    var qaSurfaceLayerFrame: CGRect { surfaceLayer.frame }
    var qaSurfaceLayerAnimationKeys: [String] { surfaceLayer.animationKeys() ?? [] }

    func qaResetCounters() {
        qaBackingCallbackCount = 0
        qaContentsScaleChangeCount = 0
    }
}

/// The container that holds real tile bodies while their tiles render from
/// surfaces.
///
/// Its whole job is to be invisible in every sense. Zero-sized AND explicitly
/// clipped — `clipsToBounds` defaults to FALSE on macOS 14+, so the original
/// "AppKit clips children to an ancestor's bounds when drawing" assumption was
/// silently untrue on the deployment target: every parked full-size body was
/// drawn into the region above the canvas and left renderable in the window's
/// composited layer tree (`checkParkedBodiesPaintNoPixels` is the pixel
/// witness). Clipping bounds drawing and compositing only — never layout,
/// timers, or semantic work — which is exactly why `isHidden` remains wrong
/// here: it would stop the layout, and with it the streaming this design
/// exists to preserve. And opaque to accessibility, because a parked body
/// IS still in the window's view tree: measured, VoiceOver reached a parked
/// transcript at `{{0, 1132}, {420, 90}}` while its tile sat at
/// `{{40, 640}, {420, 300}}` — wrong place, wrong size, detached from its owner.
/// The body is reached through its tile instead, which hands it back first
/// (`TileNSView.accessibilityChildren`).
@MainActor
final class TileSurfaceParkView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        // HIDDEN, not merely clipped. A parked body draws nothing either way, but
        // a clipped-out subtree is still walked by AppKit's per-display-cycle
        // machinery: a 20 s sample of a real 83-tile zoom session (2026-08-19)
        // showed ~0.7 s in tracking-area structural-region updates and deep
        // layout chains recursing through PARKED transcript trees — a per-frame
        // tax during gestures paid for views nobody can see. Hidden subtrees are
        // pruned from those walks. Bakes are unaffected: a re-bake requires the
        // body native and in-plane (parked pixels are not faithful), so nothing
        // ever draws a parked body from here.
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func accessibilityChildren() -> [Any]? { [] }
    override func isAccessibilityElement() -> Bool { false }
}
