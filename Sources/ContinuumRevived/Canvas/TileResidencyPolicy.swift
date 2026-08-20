import AppKit
import ContinuumRevivedCore

/// **Option A of `.plans/37`: a tile keeps its real body while it is LIVE, and
/// renders from a surface while it is quiet.**
///
/// Two measurements forced this shape, and both refuted something simpler.
///
/// Slice 1 keyed residency on the CAMERA — surfaced in motion, native at rest —
/// and its own witness killed it: reparenting a deep tile body costs ~2.1 ms out
/// and ~2.9 ms back, per tile, and a camera-keyed policy pays that twice per
/// gesture. Then `.plans/37`'s Step 0 killed the obvious alternative of leaving
/// everything surfaced: a body cannot be baked while it is parked. Its transcript's
/// `visibleRect` degenerates to a canvas-sized rect offset off its own document, so
/// a row that arrives while parked never materialises (measured: rows 10 -> 11,
/// pixels unchanged) and the offset it does present is not the native one (3.28 to
/// 7.41 mean channel difference).
///
/// Both results point one way. **Bake only while native, which is the only faithful
/// state, and reparent only when a tile crosses between live and quiet** — which is
/// rare next to camera gestures. A camera step then costs one native tile's layout
/// per LIVE tile, and nothing for the rest.
///
/// The decision is a pure function of timestamps, so the rule is witnessable
/// without a canvas, a window, or a camera.
enum TileResidencyPolicy {
    struct Tuning {
        /// How long after its last content change a tile is still live. A second,
        /// so an agent that pauses between tokens is not reparented between them.
        var contentQuietDelay: TimeInterval = 1.0
        /// The pointer must REST, not sweep. Without this, dragging the cursor
        /// across five surfaced tiles costs five promote/demote pairs (~25 ms) on
        /// the way past.
        var pointerRestDelay: TimeInterval = 0.15
        /// How often liveness is re-evaluated when nothing else prompts it. This is
        /// the worst-case latency on "a quiet tile started streaming again", during
        /// which it is still showing a picture.
        var evaluationInterval: TimeInterval = 0.1
        /// Bakes allowed in one evaluation pass. Surfacing 50 quiet tiles at once
        /// would otherwise pay ~50 ms of bake in one frame.
        var maxBakesPerPass: Int = TileSurfaceResidencyConfig.maxBakesPerTransition
        /// The zoom-equivalent density an OFF-SCREEN bake is capped at. Softness
        /// only matters where it can be seen, and bytes are what it trades against:
        /// full-density bakes for the whole canvas at zoom 2 need ~650 MB against a
        /// 256 MB budget. 1.0 = rest density; the lead-rect sharpening re-bakes a
        /// tile at full density just before it arrives on screen.
        var offscreenBakeZoomCap: Double = 1.0
        /// Hard ceiling on ONE surface's bytes, enforced by capping the scale a
        /// bake is asked for. The lead test is binary and a bake is whole-body,
        /// so at deep zoom a 760x900 body 10% on screen would bake ~98 MB for
        /// pixels mostly nobody sees — measured live (2026-08-19) as the budget
        /// pinned at its cap with refusedMemory in the thousands and every
        /// refused tile stranded native. Rest density is always allowed, whale
        /// or not: a soft tile at rest is a visible defect, a capped one at
        /// deep zoom is a slightly-soft neighbour of the tile being read.
        var maxBytesPerBakedSurface: Int = 24 << 20
        /// Sharpness promotions allowed in ONE camera step. Promoting every
        /// too-soft surfaced tile at once was the zoom-in storm: 19 promotions in
        /// a single step and a 1.65 s frame gap, in a real 89-tile session
        /// (`.plans/38`). One per step, nearest the gesture anchor first, spreads
        /// the same work across the gesture's own steps; the periphery is briefly
        /// soft while it converges — chosen over the hitch (2026-08-19), because
        /// every felt complaint has been chop and never softness.
        var maxSharpnessPromotionsPerStep: Int = 1
        /// Sharpness promotions allowed per SETTLED evaluation pass — the
        /// catch-up for tiles the per-step cap deferred, once the gesture is
        /// over. At 10 Hz a worst-case storm of ~20 sharpens in about a second,
        /// with no single frame paying for more than two reparents.
        var maxSharpnessCatchUpPromotionsPerPass: Int = 2
        /// Bakes per SETTLED pass for tiles inside the viewport itself. Separate
        /// from `maxBakesPerPass` (which off-screen work still pays) because a
        /// visible tile mid-sharpen is a visible pop waiting to happen: the
        /// settle edge promotes every soft visible tile in one beat, and this
        /// budget is what lets the very next pass give them all back at once.
        /// Zooming in shrinks the visible set, so 12 covers a real viewport;
        /// zoom-out never softens, so it cannot be asked to cover 80.
        var maxVisibleSharpenBakesPerSettledPass: Int = 12

        static let `default` = Tuning()
    }

    /// Why a tile is keeping its real body. Named rather than boolean, so a witness
    /// can assert the reason instead of inferring it from an outcome that three
    /// different rules could have produced.
    enum NativeReason: String {
        case focus
        case pointerResting
        case accessibility
        case animating
        case streaming
    }

    enum Decision: Equatable {
        case native(NativeReason)
        case surfaced
    }

    /// Everything the rule needs about one tile — and nothing about views.
    struct Liveness {
        var lastContentRevision: UInt64?
        var lastContentChangeAt: TimeInterval?
        var pointerInsideSince: TimeInterval?
        /// The last instant the pointer was RESTING in this tile — set only once
        /// `pointerRestDelay` has been met, never by mere transit. This is the
        /// exit half of the pointer hysteresis; see `decide`.
        var lastPointerRestingAt: TimeInterval?
        var hasFocus = false
        var isAnimating = false
        var lastAccessibilityCount: UInt64?
        var lastAccessibilityAccessAt: TimeInterval?
    }

    /// Focus, pointer, accessibility, self-animation, then content. The order matters only for
    /// which reason is reported, since any of them means native.
    static func decide(
        now: TimeInterval, liveness: Liveness, tuning: Tuning = .default
    ) -> Decision {
        if liveness.hasFocus { return .native(.focus) }
        if let since = liveness.pointerInsideSince, now - since >= tuning.pointerRestDelay {
            return .native(.pointerResting)
        }
        // Exit hysteresis, and it is as load-bearing as the entry rest delay. A
        // cursor jittering at a tile edge — a thumb resting on the trackpad is
        // enough — otherwise promotes and demotes the same tile several times a
        // second, for minutes, on an idle canvas: each cycle a ~10 ms reparent
        // pair plus a damaged window for WindowServer to recomposite (attributed
        // live, 2026-08-19). Keyed on rest having been ACHIEVED, never on mere
        // transit, so a sweep still promotes nothing.
        if let rested = liveness.lastPointerRestingAt,
           now - rested < tuning.contentQuietDelay {
            return .native(.pointerResting)
        }
        // Hysteresis, and it is not optional. `TileNSView.accessibilityChildren`
        // promotes on access, so without a window in which the tile STAYS native, a
        // VoiceOver user would fight the policy: every query promotes, every pass
        // 100 ms later demotes, and each cycle costs ~5 ms of reparenting while the
        // AX tree changes under them.
        if let accessed = liveness.lastAccessibilityAccessAt,
           now - accessed < tuning.contentQuietDelay {
            return .native(.accessibility)
        }
        if liveness.isAnimating { return .native(.animating) }
        if let changed = liveness.lastContentChangeAt, now - changed < tuning.contentQuietDelay {
            return .native(.streaming)
        }
        return .surfaced
    }
}
