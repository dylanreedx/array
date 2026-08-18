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
