import CoreGraphics
import Foundation

/// WS7 — every number the background renderer draws with, computed purely.
///
/// The renderer owns no maths. That is the point: pan/zoom phase, the adaptive
/// stride, the primitive bounds and the image rect are all decided here, where a
/// check can drive them across thousands of camera states with no window, no
/// display and no timing.
///
/// **Coordinate conventions** are `CanvasEngine`'s, unchanged: world Y is DOWN,
/// `viewport.(x,y)` is the world point at the viewport's top-left corner, and
/// `zoom` is screen points per world unit. `screen = (world - viewport) * zoom`.
///
/// **The grid is WORLD-ALIGNED**; base and image are SCREEN-FIXED. So only the
/// grid takes a phase from the camera, and the image rect is a pure function of
/// the viewport SIZE — never of its origin or zoom.
public enum CanvasBackgroundGeometry {

    // MARK: - Negative-safe modulo

    /// `a mod m` with the sign of `m`, via `floor`.
    ///
    /// Swift's `%` / `truncatingRemainder` take the sign of the DIVIDEND, so at
    /// a negative world origin they return a negative phase and the first grid
    /// line jumps a whole stride the instant the camera crosses zero — a visible
    /// stutter, and the exact defect this function exists to prevent. There is no
    /// correct use of a signed remainder in this file.
    public static func positiveMod(_ a: Double, _ m: Double) -> Double {
        guard m > 0, a.isFinite, m.isFinite else { return 0 }
        let r = a - m * (a / m).rounded(.down)
        // `floor` can still land exactly on `m` for values whose quotient rounds
        // up in binary; normalise the open upper end to zero so the phase range
        // is genuinely `[0, m)`.
        return (r >= m || r < 0) ? 0 : r
    }

    // MARK: - Adaptive stride

    /// Screen-point band the effective stride is kept inside. `lower` is where a
    /// grid becomes visual noise; `upper` is where it becomes too sparse to read
    /// as a grid.
    ///
    /// `upper > 2 * lower` is load-bearing, and it is what makes the band
    /// hysteretic rather than merely clamped: a double fires at `lower` and lands
    /// below `2 * lower`, which is still under `upper`, so it cannot immediately
    /// halve back; a halve fires above `upper` and lands above `upper / 2`, which
    /// is still over `lower`, so it cannot immediately double back. Any pair with
    /// `upper <= 2 * lower` flips on every step at the boundary.
    public static let minimumScreenStride: Double = 12
    public static let maximumScreenStride: Double = 32
    /// Guard rail. `2^20` world spacings is already far past any real camera.
    public static let maximumStrideMultiplier = 1 << 20

    /// The multiplier a renderer with NO prior state would choose: the smallest
    /// power of two whose screen stride reaches `minimumScreenStride`.
    public static func canonicalStrideMultiplier(spacingWorld: Double, zoom: Double) -> Int {
        guard spacingWorld > 0, zoom > 0, spacingWorld.isFinite, zoom.isFinite else { return 1 }
        var multiplier = 1
        while Double(multiplier) * spacingWorld * zoom < minimumScreenStride,
              multiplier < maximumStrideMultiplier {
            multiplier *= 2
        }
        return multiplier
    }

    /// The multiplier a renderer that is ALREADY at `previous` should move to.
    ///
    /// Doubling only below `lower`, and halving only above `upper` AND only when
    /// the halved stride still clears `lower`, is what stops the oscillation —
    /// see the band's own note. Neither move can put the stride back in the
    /// region that triggers its opposite.
    ///
    /// `previous == nil` means "no state yet" and takes the canonical answer, so
    /// a cold start and a relaunch agree.
    public static func strideMultiplier(spacingWorld: Double, zoom: Double, previous: Int?) -> Int {
        guard spacingWorld > 0, zoom > 0, spacingWorld.isFinite, zoom.isFinite else { return 1 }
        guard let previous, previous >= 1, previous <= maximumStrideMultiplier,
              previous & (previous - 1) == 0 else {
            return canonicalStrideMultiplier(spacingWorld: spacingWorld, zoom: zoom)
        }
        var multiplier = previous
        while Double(multiplier) * spacingWorld * zoom < minimumScreenStride,
              multiplier < maximumStrideMultiplier {
            multiplier *= 2
        }
        while multiplier > 1,
              Double(multiplier) * spacingWorld * zoom > maximumScreenStride,
              Double(multiplier / 2) * spacingWorld * zoom >= minimumScreenStride {
            multiplier /= 2
        }
        return multiplier
    }

    // MARK: - Grid phase

    /// The complete record of one grid solve. Everything a pixel witness needs
    /// to predict where a line lands, and everything a regression would change.
    public struct GridPhase: Equatable, Sendable {
        /// `spacing * multiplier`, in world units.
        public let strideWorld: Double
        /// `strideWorld * zoom`, in screen points.
        public let strideScreen: Double
        public let multiplier: Int
        /// Screen X of the first visible vertical line, in `[0, strideScreen)`.
        public let phaseX: Double
        /// Screen Y of the first visible horizontal line, in `[0, strideScreen)`.
        public let phaseY: Double
        /// The WORLD coordinate that first phase corresponds to. Recorded so a
        /// witness can assert the grid is anchored to the world and not merely
        /// to some in-range screen offset.
        public let firstWorldX: Double
        public let firstWorldY: Double
        public let verticalCount: Int
        public let horizontalCount: Int

        public var dotCount: Int { verticalCount * horizontalCount }

        public func verticalPositions() -> [Double] {
            (0..<verticalCount).map { phaseX + Double($0) * strideScreen }
        }

        public func horizontalPositions() -> [Double] {
            (0..<horizontalCount).map { phaseY + Double($0) * strideScreen }
        }
    }

    /// Solve the grid for one camera state.
    ///
    /// `multiplier` is supplied rather than derived so the renderer's hysteresis
    /// STATE is the only thing that decides it — a phase solve that re-derived
    /// the multiplier canonically would silently undo the hysteresis.
    public static func gridPhase(
        viewport: CanvasViewport,
        viewportSize: CGSize,
        spacingWorld: Double,
        multiplier: Int
    ) -> GridPhase {
        let spacing = CanvasBackgroundConfiguration.clampedSpacing(spacingWorld)
        let zoom = (viewport.zoom.isFinite && viewport.zoom > 0) ? viewport.zoom : 1
        let safeMultiplier = max(1, min(multiplier, maximumStrideMultiplier))
        let strideWorld = spacing * Double(safeMultiplier)
        let strideScreen = strideWorld * zoom
        let width = viewportSize.width.isFinite ? max(0, Double(viewportSize.width)) : 0
        let height = viewportSize.height.isFinite ? max(0, Double(viewportSize.height)) : 0

        guard strideScreen > 0 else {
            return GridPhase(strideWorld: strideWorld, strideScreen: 0, multiplier: safeMultiplier,
                             phaseX: 0, phaseY: 0, firstWorldX: 0, firstWorldY: 0,
                             verticalCount: 0, horizontalCount: 0)
        }

        let originX = viewport.x.isFinite ? viewport.x : 0
        let originY = viewport.y.isFinite ? viewport.y : 0

        // The first world line at or after the viewport origin, then its screen
        // position. Both halves are floor-based, so a negative origin behaves
        // exactly like a positive one.
        let firstWorldX = (originX / strideWorld).rounded(.up) * strideWorld
        let firstWorldY = (originY / strideWorld).rounded(.up) * strideWorld
        // Equivalent to `(firstWorld - origin) * zoom`, but computed by positive
        // modulo so floating error can never produce a phase of exactly
        // `strideScreen` (which would draw the first line one stride late).
        let phaseX = positiveMod(-originX * zoom, strideScreen)
        let phaseY = positiveMod(-originY * zoom, strideScreen)

        // Analytic bounds. Nothing here allocates per world unit: the counts are
        // a function of the VIEWPORT, so a canvas panned to world 10^9 draws
        // exactly as many primitives as one at the origin.
        // `floor((size - phase) / stride) + 1`, floored at zero: when the first
        // line already lies past the edge the numerator is negative and the
        // expression falls to 0 on its own.
        let verticalCount = width > 0 ? max(0, Int(((width - phaseX) / strideScreen).rounded(.down)) + 1) : 0
        let horizontalCount = height > 0 ? max(0, Int(((height - phaseY) / strideScreen).rounded(.down)) + 1) : 0

        return GridPhase(
            strideWorld: strideWorld,
            strideScreen: strideScreen,
            multiplier: safeMultiplier,
            phaseX: phaseX,
            phaseY: phaseY,
            firstWorldX: firstWorldX,
            firstWorldY: firstWorldY,
            verticalCount: verticalCount,
            horizontalCount: horizontalCount
        )
    }

    /// The analytic ceiling a witness holds the renderer to.
    public static func maximumPrimitiveCount(viewportSize: CGSize, strideScreen: Double) -> Int {
        guard strideScreen > 0, viewportSize.width > 0, viewportSize.height > 0 else { return 0 }
        let vertical = Int((Double(viewportSize.width) / strideScreen).rounded(.up)) + 1
        let horizontal = Int((Double(viewportSize.height) / strideScreen).rounded(.up)) + 1
        return vertical + horizontal
    }

    // MARK: - Device-pixel alignment

    /// Centre a `lineWidthDevice`-wide stroke on a device pixel boundary.
    ///
    /// Reported SEPARATELY from `GridPhase` (never folded into it) so a pixel
    /// witness can tell a real phase change from a rounding difference.
    public static func alignedPosition(_ position: Double, backingScale: Double, lineWidthDevice: Double) -> Double {
        guard backingScale > 0, backingScale.isFinite, position.isFinite else { return position }
        return ((position * backingScale - 0.5 * lineWidthDevice).rounded() + 0.5 * lineWidthDevice) / backingScale
    }

    // MARK: - Image geometry

    /// The SCREEN rect a background image occupies. A pure function of the image's
    /// pixel size, the viewport SIZE and the content mode — deliberately not of
    /// `viewport.x/y/zoom`, which is what "screen-fixed" means mechanically.
    public static func imageRect(
        imageSize: CGSize,
        viewportSize: CGSize,
        mode: CanvasBackgroundImageMode
    ) -> CGRect {
        let iw = Double(imageSize.width), ih = Double(imageSize.height)
        let vw = Double(viewportSize.width), vh = Double(viewportSize.height)
        guard iw > 0, ih > 0, vw > 0, vh > 0, iw.isFinite, ih.isFinite, vw.isFinite, vh.isFinite else {
            return .zero
        }
        let scale: Double
        switch mode {
        case .fill: scale = max(vw / iw, vh / ih)
        case .fit: scale = min(vw / iw, vh / ih)
        }
        let w = iw * scale, h = ih * scale
        return CGRect(x: (vw - w) / 2, y: (vh - h) / 2, width: w, height: h)
    }

    /// The decode target for one viewport, in PIXELS, bucketed so ordinary window
    /// resizing does not thrash the cache, and hard-capped so a huge image can
    /// never be decoded at its native size.
    public static let decodeBucketPixels: Int = 256
    public static let maximumDecodePixelDimension: Int = 4096

    public static func decodeTargetPixels(viewportSize: CGSize, backingScale: Double) -> Int {
        let scale = (backingScale.isFinite && backingScale > 0) ? backingScale : 1
        let longest = max(Double(viewportSize.width), Double(viewportSize.height)) * scale
        guard longest.isFinite, longest > 0 else { return decodeBucketPixels }
        let bucketed = Int((longest / Double(decodeBucketPixels)).rounded(.up)) * decodeBucketPixels
        return min(max(bucketed, decodeBucketPixels), maximumDecodePixelDimension)
    }
}
