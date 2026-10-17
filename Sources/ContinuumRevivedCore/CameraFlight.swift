import CoreGraphics
import Foundation

/// A navigation jump's camera move: from where the camera is to where a jump
/// framed it, over a short eased flight instead of a one-frame cut (Dylan,
/// 2026-10-05: the launch film glided and the app cut, so the film showed motion
/// the app did not have).
///
/// The path is the film's cameraModel v2 move, so the two cannot drift apart:
/// the world point at the canvas centre and log(zoom) each ease on their own
/// clock, the centre leading a zoom-in and trailing a zoom-out by `zoomLag` of
/// the move, so the camera never travels across the canvas zoomed in. Both
/// halves use the same cubic Bezier (0.4, 0, 0.2, 1): no jolt on take-off, a
/// long soft landing. Exact at both ends.
public struct CameraFlight: Equatable, Sendable {
    public let from: CanvasViewport
    public let to: CanvasViewport
    public let width: Double
    public let height: Double
    public let duration: TimeInterval

    /// The share of the move by which the zoom trails (zoom-in) or leads (zoom-out) the pan.
    public static let zoomLag = 0.12
    public static let minDuration: TimeInterval = 0.30
    public static let maxDuration: TimeInterval = 0.70

    /// Nil when there is nowhere to go: a jump to where the camera already is.
    public init?(from: CanvasViewport, to: CanvasViewport, viewportSize size: CGSize) {
        let width = Double(size.width), height = Double(size.height)
        guard width > 0, height > 0, from.zoom > 0, to.zoom > 0,
              [from.x, from.y, from.zoom, to.x, to.y, to.zoom].allSatisfy(\.isFinite) else { return nil }
        let c0 = Self.centre(of: from, width: width, height: height)
        let c1 = Self.centre(of: to, width: width, height: height)
        // Distance in canvas widths at the wider end, where most of the pan happens.
        let widths = hypot(c1.x - c0.x, c1.y - c0.y) * min(from.zoom, to.zoom) / width
        let octaves = abs(log2(to.zoom / from.zoom))
        guard widths > 0.001 || octaves > 0.001 else { return nil }
        self.from = from
        self.to = to
        self.width = width
        self.height = height
        self.duration = min(Self.maxDuration,
                            Self.minDuration + 0.10 * min(widths, 3) + 0.08 * min(octaves, 4))
    }

    /// The camera `t` seconds into the flight.
    public func viewport(at t: TimeInterval) -> CanvasViewport {
        let p = t / duration
        if p <= 0 { return from }
        if p >= 1 { return to }
        let zooms = abs(log(to.zoom) - log(from.zoom)) > 1e-9
        let span = zooms ? 1 - Self.zoomLag : 1
        let lead = Self.clamp01(p / span), trail = Self.clamp01((p - (1 - span)) / span)
        let (pc, pz) = !zooms ? (Self.clamp01(p), Self.clamp01(p)) : to.zoom > from.zoom ? (lead, trail) : (trail, lead)
        let ec = Self.ease(pc), ez = Self.ease(pz)
        let c0 = Self.centre(of: from, width: width, height: height)
        let c1 = Self.centre(of: to, width: width, height: height)
        let cx = c0.x + (c1.x - c0.x) * ec, cy = c0.y + (c1.y - c0.y) * ec
        let zoom = exp(log(from.zoom) + (log(to.zoom) - log(from.zoom)) * ez)
        return CanvasViewport(x: cx - width / 2 / zoom, y: cy - height / 2 / zoom, zoom: zoom)
    }

    private static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    private static func centre(of v: CanvasViewport, width: Double, height: Double) -> (x: Double, y: Double) {
        (v.x + width / 2 / v.zoom, v.y + height / 2 / v.zoom)
    }

    /// cubic-bezier(0.4, 0, 0.2, 1), solved for x by bisection (monotone here).
    static func ease(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<50 {
            let mid = (lo + hi) / 2
            if bezier(mid, 0.4, 0.2) < x { lo = mid } else { hi = mid }
        }
        return bezier((lo + hi) / 2, 0.0, 1.0)
    }
}
