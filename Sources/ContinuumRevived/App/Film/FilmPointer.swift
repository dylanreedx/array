// Film harness: the pointer track's pure math. Everything here is a function of its
// arguments (no views, no clock), so `--film-scene-check` asserts it offline and the
// Remotion overlay can reproduce it exactly from `frames.json`.
//
// Coordinates: "window points" are TOP-LEFT origin over the window's content area
// (`contentLayoutRect`), the same space as `frames.json`'s `pointSize`. The canvas
// fills that area and is flipped, so a canvas point and a window point coincide; the
// director still converts through the view tree rather than assuming it.
// Compiled only into the film build (`scripts/film-capture.sh`, -DARRAY_FILM).
#if ARRAY_FILM
import AppKit
import ContinuumRevivedCore

/// Closed-form damped spring, ported verbatim from the overlay's TS:
///
///     springAt(t,{hz,zeta}) = zeta<1 ? 1-exp(-zeta*w*t)*(cos(wd*t)+(zeta*w/wd)*sin(wd*t))
///                                    : 1-exp(-w*t)*(1+w*t),   w=2πhz, wd=w*sqrt(1-zeta²)
///
/// `normalized` lands exactly at `duration`: e(p) = springAt(p*dur)/springAt(dur), 1 at p>=1.
struct FilmSpring: Equatable {
    var hz: Double
    var zeta: Double

    static let snappy = FilmSpring(hz: 2.4, zeta: 0.72)
    static let soft = FilmSpring(hz: 1.35, zeta: 0.9)
    static let glide = FilmSpring(hz: 1.0, zeta: 1)

    static func named(_ name: String) -> FilmSpring? {
        switch name {
        case "snappy": return .snappy
        case "soft": return .soft
        case "glide": return .glide
        default: return nil
        }
    }

    func at(_ t: Double) -> Double {
        let w = 2 * Double.pi * hz
        if zeta < 1 {
            let wd = w * (1 - zeta * zeta).squareRoot()
            return 1 - exp(-zeta * w * t) * (cos(wd * t) + (zeta * w / wd) * sin(wd * t))
        }
        return 1 - exp(-w * t) * (1 + w * t)
    }

    /// `duration` in seconds.
    func normalized(_ p: Double, duration: Double) -> Double {
        if p >= 1 { return 1 }
        if p <= 0 { return 0 }
        let end = at(duration)
        return end == 0 ? p : at(p * duration) / end
    }
}

/// Every easing a scene can name. `nil` means the house camera curve.
///
///  - `cam` | `linear` | `inOut`: cubic beziers (`FilmEase`);
///  - `pan`: cubic-bezier(0.4, 0, 0.2, 1), zero start slope, the cameraModel v2 default
///    for camera, pan and zoom (review 16, "Camera model");
///  - `smoother`: smootherstep 6p⁵ − 15p⁴ + 10p³, zero start and end slope;
///  - `aim`: cubic-bezier(0.65, 0, 0.35, 1), the measured ease of a real aimed pointer
///    move (identical control points to `inOut`; the pointer's default);
///  - `momentum`: trackpad-pan release, e(p) = (1-exp(-5p))/(1-exp(-5));
///  - `spring:snappy|soft|glide`: `FilmSpring.normalized` over the action's duration.
enum FilmCurve: Equatable {
    case bezier(FilmEase)
    case spring(FilmSpring)
    case momentum
    case smoother

    static func named(_ name: String?) -> FilmCurve? {
        guard let name else { return .bezier(.cam) }
        switch name {
        case "cam": return .bezier(.cam)
        case "linear": return .bezier(.linear)
        case "inOut", "aim": return .bezier(.inOut)
        case "pan": return .bezier(.pan)
        case "smoother": return .smoother
        case "momentum": return .momentum
        default:
            guard name.hasPrefix("spring:"), let spring = FilmSpring.named(String(name.dropFirst(7))) else { return nil }
            return .spring(spring)
        }
    }

    /// Pointer motion: `spring` (a preset name) wins over `ease`; neither is `aim`.
    static func pointer(spring: String?, ease: String?) -> FilmCurve? {
        if let spring { return FilmSpring.named(spring).map(FilmCurve.spring) }
        return named(ease ?? "aim")
    }

    /// `duration` in seconds (only springs read it).
    func value(_ p: Double, duration: Double) -> Double {
        switch self {
        case let .bezier(ease): return ease.value(p)
        case let .spring(spring): return spring.normalized(p, duration: duration)
        case .momentum: return FilmPointerMath.momentum(p)
        case .smoother: return FilmCameraMath.smootherstep(p)
        }
    }

    /// The curve's steepest slope de/dp over [0, 1] (sampled; 1 is linear). The speed
    /// guard multiplies it by distance / duration to get a move's peak speed.
    func peakSlope(duration: Double) -> Double {
        let samples = 2000
        var peak = 0.0, last = value(0, duration: duration)
        for i in 1...samples {
            let next = value(Double(i) / Double(samples), duration: duration)
            peak = max(peak, abs(next - last) * Double(samples))
            last = next
        }
        return peak
    }

    /// A spring below critical damping overshoots and comes back: its path is not
    /// monotone, by design.
    var isMonotone: Bool {
        if case let .spring(spring) = self { return spring.zeta >= 1 }
        return true
    }
}

extension FilmEase: Equatable {
    static func == (a: FilmEase, b: FilmEase) -> Bool {
        a.p1 == b.p1 && a.p2 == b.p2
    }
}

enum FilmPointerMath {
    static let defaultArc = 0.04
    static let modes: Set<String> = ["arrow", "hand", "grab", "pinch", "scroll"]
    /// Frames a pinch takes to bring the pointer onto the zoom's fixed point.
    static let pinchApproachFrames = 12

    static func momentum(_ p: Double) -> Double {
        if p <= 0 { return 0 }
        if p >= 1 { return 1 }
        return (1 - exp(-5 * p)) / (1 - exp(-5))
    }

    /// Straight line from `a` to `b` at progress `e`, bowed sideways by
    /// arc * |b-a| * sin(πe): zero at both ends, so the arc never moves an endpoint.
    /// The bow is to the left of travel in top-left space (a rightward move bows up).
    static func path(from a: CGPoint, to b: CGPoint, e: Double, arc: Double) -> CGPoint {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let bow = arc * sin(Double.pi * e)
        return CGPoint(x: Double(a.x) + dx * e + dy * bow, y: Double(a.y) + dy * e - dx * bow)
    }

    /// The canvas-space point the v0 -> v1 similarity holds still: the world point
    /// under it is the same in both viewports, and `FilmDirector.interpolate` keeps it
    /// still on every frame in between (the check asserts both). Nil when the zoom
    /// does not change (a pure pan has no fixed point).
    static func fixedPoint(_ v0: CanvasViewport, _ v1: CanvasViewport) -> CGPoint? {
        let k = 1 / v0.zoom - 1 / v1.zoom
        guard abs(k) > 1e-12 else { return nil }
        return CGPoint(x: (v1.x - v0.x) / k, y: (v1.y - v0.y) / k)
    }

    /// A pan never zooms: the destination centres `rect` at the current zoom.
    static func panViewport(from v0: CanvasViewport, centering rect: CGRect, size: CGSize) -> CanvasViewport {
        CanvasViewport(x: Double(rect.midX) - Double(size.width) / 2 / v0.zoom,
                       y: Double(rect.midY) - Double(size.height) / 2 / v0.zoom, zoom: v0.zoom)
    }

    /// A hand-grab pan: the pointer rides the world point it grabbed, so its screen
    /// delta is the camera's (negated, in screen units).
    static func grabbedPointer(start: CGPoint, from v0: CanvasViewport, to v: CanvasViewport) -> CGPoint {
        CGPoint(x: Double(start.x) - (v.x - v0.x) * v.zoom, y: Double(start.y) - (v.y - v0.y) * v.zoom)
    }
}

/// The scripted pointer the app experiences. Until a scene moves it, it waits
/// off-window so it can fly in. `placed` turns true once an AUTHORED pointer verb
/// (pointer move, pan, pinch) has positioned it; a scene that never does (board-story)
/// gets its drags started on the card without a warning.
struct FilmPointerState {
    var x: Double
    var y: Double
    var down = false
    var mode = "arrow"
    var placed = false

    var point: CGPoint {
        get { CGPoint(x: x, y: y) }
        set { x = Double(newValue.x); y = Double(newValue.y) }
    }

    static func offWindow(_ size: CGSize) -> FilmPointerState {
        FilmPointerState(x: Double(size.width) + 60, y: Double(size.height) * 0.7)
    }
}

/// cameraModel v2 (review 16, "Camera model"): the pure math of a camera move whose
/// centre and zoom run on separate progress values, plus the speed guard. Every
/// function is a function of its arguments, so the witness asserts it offline.
///
///  - A zoom pivots on its TARGET: the camera centre is interpolated in world space and
///    the zoom in log space. Zooming in, the centre leads (e(p/0.88)) and the zoom
///    trails (e((p-0.12)/0.88)); zooming out, they swap. The target ends dead centre and
///    the content grows from the middle instead of streaming away from a corner.
///  - A move that does not zoom has no lag: the centre runs on e(p).
enum FilmCameraMath {
    static let zoomLag = 0.12
    /// Peak screen pan speed the guard allows, in canvas widths per second.
    static let maxPanWidthsPerSecond = 1.2
    /// Peak zoom rate the guard allows, in octaves (doublings) per second.
    static let maxZoomOctavesPerSecond = 1.1

    static func smootherstep(_ p: Double) -> Double {
        if p <= 0 { return 0 }
        if p >= 1 { return 1 }
        return p * p * p * (p * (6 * p - 15) + 10)
    }

    static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    static func zooms(_ v0: CanvasViewport, _ v1: CanvasViewport) -> Bool {
        abs(Foundation.log(v1.zoom) - Foundation.log(v0.zoom)) > 1e-9
    }

    /// The world point at the canvas centre.
    static func centre(of v: CanvasViewport, size: CGSize) -> CGPoint {
        CGPoint(x: v.x + Double(size.width) / 2 / v.zoom, y: v.y + Double(size.height) / 2 / v.zoom)
    }

    static func viewport(centre c: CGPoint, zoom: Double, size: CGSize) -> CanvasViewport {
        CanvasViewport(x: Double(c.x) - Double(size.width) / 2 / zoom, y: Double(c.y) - Double(size.height) / 2 / zoom, zoom: zoom)
    }

    /// Raw (un-eased) progress of the centre and of the zoom at move progress `p`.
    static func split(_ p: Double, v0: CanvasViewport, v1: CanvasViewport) -> (centre: Double, zoom: Double) {
        guard zooms(v0, v1) else { return (clamp01(p), clamp01(p)) }
        let span = 1 - zoomLag
        let lead = clamp01(p / span), trail = clamp01((p - zoomLag) / span)
        return v1.zoom > v0.zoom ? (lead, trail) : (trail, lead)
    }

    /// The fraction of the move's duration each eased half spans (for springs, and for
    /// the per-frame speed bound): 0.88 when the move zooms, else 1.
    static func span(_ v0: CanvasViewport, _ v1: CanvasViewport) -> Double { zooms(v0, v1) ? 1 - zoomLag : 1 }

    /// v0 -> v1 at move progress `p` (0...1) over `duration` seconds. Exact at both ends.
    static func interpolate(_ v0: CanvasViewport, _ v1: CanvasViewport, p: Double, curve: FilmCurve,
                            duration: Double, size: CGSize) -> CanvasViewport {
        if p <= 0 { return v0 }
        if p >= 1 { return v1 }
        let (pc, pz) = split(p, v0: v0, v1: v1)
        let eased = duration * span(v0, v1)
        let ec = curve.value(pc, duration: eased), ez = curve.value(pz, duration: eased)
        let c0 = centre(of: v0, size: size), c1 = centre(of: v1, size: size)
        let c = CGPoint(x: Double(c0.x) + Double(c1.x - c0.x) * ec, y: Double(c0.y) + Double(c1.y - c0.y) * ec)
        let z = exp(Foundation.log(v0.zoom) + (Foundation.log(v1.zoom) - Foundation.log(v0.zoom)) * ez)
        return viewport(centre: c, zoom: z, size: size)
    }

    struct Speed: Equatable {
        /// Peak screen speed of the camera centre, canvas widths per second.
        var panWidthsPerSecond: Double
        /// Peak |d log2(zoom) / dt|, octaves per second.
        var zoomOctavesPerSecond: Double

        var warnings: [String] {
            var all: [String] = []
            if panWidthsPerSecond > FilmCameraMath.maxPanWidthsPerSecond {
                all.append(String(format: "peak pan %.2f canvas widths/s > %.1f", panWidthsPerSecond, FilmCameraMath.maxPanWidthsPerSecond))
            }
            if zoomOctavesPerSecond > FilmCameraMath.maxZoomOctavesPerSecond {
                all.append(String(format: "peak zoom %.2f octaves/s > %.1f", zoomOctavesPerSecond, FilmCameraMath.maxZoomOctavesPerSecond))
            }
            return all
        }
    }

    /// Peak speeds of a v0 -> v1 move: the curve's peak slope x distance / duration,
    /// where an eased half that spans only `span` of the move runs 1/span faster. The pan
    /// distance is the world centre distance at the SMALLER zoom (the pan leads a zoom-in
    /// and trails a zoom-out, so it happens mostly near the wide end), in canvas widths.
    /// `staggered` is cameraModel v2's split; false is the v1 similarity move.
    static func peakSpeed(from v0: CanvasViewport, to v1: CanvasViewport, curve: FilmCurve, duration: Double,
                          size: CGSize, staggered: Bool) -> Speed {
        guard duration > 0 else { return Speed(panWidthsPerSecond: 0, zoomOctavesPerSecond: 0) }
        let span = staggered ? self.span(v0, v1) : 1
        let slope = curve.peakSlope(duration: duration * span) / span
        let c0 = centre(of: v0, size: size), c1 = centre(of: v1, size: size)
        let world = hypot(Double(c1.x - c0.x), Double(c1.y - c0.y))
        let widths = world * min(v0.zoom, v1.zoom) / max(Double(size.width), 1)
        let octaves = abs(log2(v1.zoom / v0.zoom))
        return Speed(panWidthsPerSecond: slope * widths / duration, zoomOctavesPerSecond: slope * octaves / duration)
    }
}
#endif
