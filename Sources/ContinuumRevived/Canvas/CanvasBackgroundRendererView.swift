import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// WS7 — the canvas background. **One** screen-sized, hit-transparent view,
/// installed directly below `worldPlane`.
///
/// ## Why one view, below the plane, and not inside it
///
/// The base fill and the image are SCREEN-FIXED: they must not move when the
/// camera does. Everything parented to `CanvasWorldPlaneView` inherits the
/// camera by construction (the plane's `bounds` IS the camera), so anything that
/// must stay still cannot live there. The grid, which IS world-aligned, still
/// draws here rather than in the plane — it takes its phase from the camera
/// arithmetic instead of from the view hierarchy, which is what lets one view do
/// both jobs.
///
/// It is a sibling BELOW the plane rather than the canvas's own `drawRect` for
/// two reasons: `CanvasNSView.applyTokens()` already owns the canvas layer's
/// background colour, and a separate view can be invalidated for a camera step
/// without marking the canvas — and therefore the whole tile tree — as needing
/// display.
///
/// ## What a camera step costs here
///
/// `updateCamera` is arithmetic plus, at most, one `needsDisplay = true`. It
/// never lays out, never allocates per world unit, never touches a tile or a
/// zone, and never decodes. `draw(_:)` emits at most ONE stroked path and ONE
/// filled path, both bounded by `viewport / stride` — a canvas panned to world
/// 10^9 draws exactly as many primitives as one at the origin.
///
/// The file lives under `Canvas/`, which `scripts/check-color-hygiene.sh` scans,
/// so it constructs no colour of its own: a user's exact colour arrives as a
/// `CGColor` from `CanvasBackgroundRGBA` (Core) and the system default is the
/// `SurfaceToken.canvas` token.
@MainActor
final class CanvasBackgroundRendererView: NSView {

    /// Everything one draw resolved to. This is the witness surface: it records
    /// the SEMANTIC phase and the device-ALIGNED phase separately, because a
    /// half-pixel alignment difference is not a phase regression and a check that
    /// conflated them would either flake or go blind.
    struct RenderRecord: Equatable {
        var viewport = CanvasViewport(x: 0, y: 0, zoom: 1)
        var size: CGSize = .zero
        var backingScale: Double = 1
        var pattern: CanvasBackgroundPattern = .solid
        var spacingWorld: Double = CanvasBackgroundConfiguration.defaultSpacing
        var strideMultiplier: Int = 1
        var strideWorld: Double = 0
        var strideScreen: Double = 0
        var phaseX: Double = 0
        var phaseY: Double = 0
        var alignedPhaseX: Double = 0
        var alignedPhaseY: Double = 0
        var firstWorldX: Double = 0
        var firstWorldY: Double = 0
        var lineCount = 0
        var dotCount = 0
        /// Procedural pattern paths emitted. The contract is "one procedural
        /// pattern path"; this is how that is checked rather than asserted.
        var pathCount = 0
        var baseRGBA8: [Int] = []
        var patternRGBA8: [Int] = []
        var imageRect: CGRect = .zero
        var imageOpacity: Double = 0
        var imageDrawn = false
        var fellBackToPattern = false
    }

    struct QAStats: Equatable {
        /// Every `draw(_:)` that actually ran.
        var renderPasses = 0
        /// Every `updateCamera` call, including ones that changed nothing.
        var cameraUpdates = 0
        /// Camera updates that ended in an invalidation. A pan that moves the
        /// grid MUST raise this — it is the positive control for every "the
        /// image did not move" assertion.
        var cameraInvalidations = 0
        /// Image requests the renderer issued. A camera update must add zero.
        var imageRequests = 0
        var missingAssetWarnings = 0
    }

    private(set) var qaStats = QAStats()
    private(set) var qaLastRecord = RenderRecord()
    func qaResetStats() { qaStats = QAStats() }

    /// Live sublayer/subview census: the contract forbids a layer or a view per
    /// line or per dot, and this is how that is observed rather than believed.
    var qaSublayerCount: Int { layer?.sublayers?.count ?? 0 }
    var qaSubviewCount: Int { subviews.count }

    // MARK: - State

    private var configuration: CanvasBackgroundConfiguration = .systemDefault
    private var viewport = CanvasViewport(x: 0, y: 0, zoom: 1)
    /// The hysteresis state. It is renderer-INSTANCE state on purpose: the whole
    /// point of hysteresis is that the answer depends on where you came from.
    private var strideMultiplierState: Int?
    private var resolvedImage: CGImage?
    private var resolvedImageKey: CanvasBackgroundImageCache.Key?
    private(set) var missingAssetWarning: String?

    let imageCache: CanvasBackgroundImageCache

    /// Backing scale, injected for checks (an offscreen fixture window reports
    /// whatever display it was created against, which would make a pixel witness
    /// machine-dependent).
    var backingScaleOverride: Double?

    var effectiveBackingScale: Double {
        if let backingScaleOverride { return backingScaleOverride }
        return Double(window?.backingScaleFactor ?? 2)
    }

    init(imageCache: CanvasBackgroundImageCache) {
        self.imageCache = imageCache
        super.init(frame: .zero)
        // No layer properties are ever written here, so there is nothing for Core
        // Animation to animate implicitly. Content comes from `draw(_:)` only.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityIdentifier("ContinuumCanvasBackground")
        setAccessibilityElement(false)
        imageCache.onImageAvailable = { [weak self] key in
            guard let self, key == self.pendingImageKey else { return }
            self.resolvedImage = self.imageCache.image(for: key)
            self.resolvedImageKey = key
            self.missingAssetWarning = nil
            self.needsDisplay = true
        }
        imageCache.onDecodeFailed = { [weak self] id in
            guard let self else { return }
            self.noteMissingAsset(id)
        }
    }

    private var pendingImageKey: CanvasBackgroundImageCache.Key?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Backgrounds are never a click target: marquee selection, pointer pan and
    /// background clicks all belong to the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isOpaque: Bool { false }

    // MARK: - Configuration

    func setConfiguration(_ configuration: CanvasBackgroundConfiguration) {
        guard configuration != self.configuration else { return }
        let imageChanged = configuration.image?.assetID != self.configuration.image?.assetID
            || configuration.image?.mode != self.configuration.image?.mode
            // 0% is not "faded out", it is "do not decode"; crossing that edge in
            // either direction changes whether an image is needed at all.
            || (configuration.image?.opacity == .hidden) != (self.configuration.image?.opacity == .hidden)
        let spacingChanged = configuration.spacing != self.configuration.spacing
        self.configuration = configuration
        // Only a SPACING change re-anchors the stride: the hysteresis state
        // describes a spacing that no longer exists. A colour or pattern edit
        // must not silently re-canonicalise the multiplier.
        if spacingChanged { strideMultiplierState = nil }
        lastAppliedPhase = nil
        if imageChanged {
            resolvedImage = nil
            resolvedImageKey = nil
            missingAssetWarning = nil
            requestImageIfNeeded()
        }
        needsDisplay = true
    }

    var currentConfiguration: CanvasBackgroundConfiguration { configuration }

    /// Point the background at a camera state. **This is the whole camera path**:
    /// no layout, no decode, no tile or zone work.
    func updateCamera(viewport: CanvasViewport) {
        qaStats.cameraUpdates += 1
        self.viewport = viewport
        let multiplier = CanvasBackgroundGeometry.strideMultiplier(
            spacingWorld: configuration.spacing, zoom: viewport.zoom, previous: strideMultiplierState)
        strideMultiplierState = multiplier
        // A solid background with no image has nothing that depends on the
        // camera, so it is not invalidated at all — that zero is meaningful and
        // is asserted alongside a non-zero control.
        guard configuration.pattern.drawsGrid else { return }
        let phase = CanvasBackgroundGeometry.gridPhase(
            viewport: viewport, viewportSize: bounds.size,
            spacingWorld: configuration.spacing, multiplier: multiplier)
        guard phase != lastAppliedPhase else { return }
        lastAppliedPhase = phase
        qaStats.cameraInvalidations += 1
        needsDisplay = true
    }

    private var lastAppliedPhase: CanvasBackgroundGeometry.GridPhase?

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        // The viewport SIZE is part of the image's cache key (and only the size —
        // see `decodeTargetPixels`), so a resize is the one geometry event that
        // may legitimately decode.
        lastAppliedPhase = nil
        requestImageIfNeeded()
        needsDisplay = true
    }

    /// Only `.systemDefault` follows the appearance; a custom colour is exact in
    /// both. Redrawing unconditionally is still correct and costs one pass on an
    /// event that happens when the user changes their system theme.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        lastAppliedPhase = nil
        requestImageIfNeeded()
        needsDisplay = true
    }

    // MARK: - Image

    private func noteMissingAsset(_ id: CanvasBackgroundAssetID) {
        // Coalesced: one warning per asset, and it names the DIGEST prefix, never
        // a path or the user's filename.
        let text = "Background image \(id.shortDescription) is missing or unreadable — showing the base colour and pattern instead."
        guard missingAssetWarning != text else { return }
        missingAssetWarning = text
        qaStats.missingAssetWarnings += 1
        resolvedImage = nil
        resolvedImageKey = nil
        needsDisplay = true
    }

    /// Ask the cache for the image the current configuration and geometry need.
    /// Called from configuration, size and backing changes — never from
    /// `updateCamera`.
    func requestImageIfNeeded() {
        guard let spec = configuration.image, spec.opacity != .hidden else {
            pendingImageKey = nil
            return
        }
        guard bounds.width > 0, bounds.height > 0 else { return }
        qaStats.imageRequests += 1
        switch imageCache.request(spec: spec, viewportSize: bounds.size, backingScale: effectiveBackingScale) {
        case .ready(let key):
            pendingImageKey = key
            resolvedImage = imageCache.image(for: key)
            resolvedImageKey = key
            missingAssetWarning = nil
        case .pending(let key):
            pendingImageKey = key
        case .failed(let id):
            pendingImageKey = nil
            noteMissingAsset(id)
        }
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        qaStats.renderPasses += 1

        var record = RenderRecord()
        record.viewport = viewport
        record.size = bounds.size
        record.backingScale = effectiveBackingScale
        record.pattern = configuration.pattern
        record.spacingWorld = configuration.spacing

        // 1 — BASE FILL. Screen-fixed: the whole view, always.
        let baseColor = resolvedColor(configuration.base, fallback: SurfaceToken.canvas)
        record.baseRGBA8 = rgba8(of: baseColor)
        context.setFillColor(baseColor)
        context.fill(bounds)

        // 2 — IMAGE. Also screen-fixed. Its rect is a function of the viewport
        // SIZE and the content mode only; `viewport.x/y/zoom` do not appear.
        if let spec = configuration.image {
            record.imageOpacity = spec.opacity.value
            if spec.opacity != .hidden, let image = resolvedImage {
                let rect = CanvasBackgroundGeometry.imageRect(
                    imageSize: CGSize(width: image.width, height: image.height),
                    viewportSize: bounds.size,
                    mode: spec.mode)
                record.imageRect = rect
                record.imageDrawn = true
                context.saveGState()
                context.clip(to: bounds)
                context.setAlpha(CGFloat(spec.opacity.value))
                // The view is flipped and `CGContext.draw` is not, so the image
                // is flipped back about its own rect. Doing this with a transform
                // rather than an `NSImage` draw keeps the whole path CGImage-only
                // and off any AppKit caching.
                context.translateBy(x: 0, y: rect.origin.y * 2 + rect.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: rect)
                context.restoreGState()
            } else if spec.opacity != .hidden {
                record.fellBackToPattern = true
            }
        }

        // 3 — ONE procedural pattern path. World-aligned: this is the only stage
        // the camera reaches.
        if configuration.pattern.drawsGrid {
            let multiplier = strideMultiplierState
                ?? CanvasBackgroundGeometry.canonicalStrideMultiplier(
                    spacingWorld: configuration.spacing, zoom: viewport.zoom)
            strideMultiplierState = multiplier
            let phase = CanvasBackgroundGeometry.gridPhase(
                viewport: viewport, viewportSize: bounds.size,
                spacingWorld: configuration.spacing, multiplier: multiplier)
            lastAppliedPhase = phase
            record.strideMultiplier = phase.multiplier
            record.strideWorld = phase.strideWorld
            record.strideScreen = phase.strideScreen
            record.phaseX = phase.phaseX
            record.phaseY = phase.phaseY
            record.firstWorldX = phase.firstWorldX
            record.firstWorldY = phase.firstWorldY

            let scale = effectiveBackingScale
            let patternColor = resolvedColor(configuration.patternColor, fallback: SurfaceToken.canvas)
            record.patternRGBA8 = rgba8(of: patternColor)

            switch configuration.pattern {
            case .solid:
                break
            case .lines:
                let lineWidthDevice: Double = 1
                record.alignedPhaseX = CanvasBackgroundGeometry.alignedPosition(
                    phase.phaseX, backingScale: scale, lineWidthDevice: lineWidthDevice)
                record.alignedPhaseY = CanvasBackgroundGeometry.alignedPosition(
                    phase.phaseY, backingScale: scale, lineWidthDevice: lineWidthDevice)
                let path = CGMutablePath()
                for x in phase.verticalPositions() {
                    let aligned = CanvasBackgroundGeometry.alignedPosition(
                        x, backingScale: scale, lineWidthDevice: lineWidthDevice)
                    path.move(to: CGPoint(x: aligned, y: 0))
                    path.addLine(to: CGPoint(x: aligned, y: bounds.height))
                }
                for y in phase.horizontalPositions() {
                    let aligned = CanvasBackgroundGeometry.alignedPosition(
                        y, backingScale: scale, lineWidthDevice: lineWidthDevice)
                    path.move(to: CGPoint(x: 0, y: aligned))
                    path.addLine(to: CGPoint(x: bounds.width, y: aligned))
                }
                record.lineCount = phase.verticalCount + phase.horizontalCount
                if !path.isEmpty {
                    record.pathCount = 1
                    context.setStrokeColor(patternColor)
                    context.setLineWidth(CGFloat(lineWidthDevice / scale))
                    context.addPath(path)
                    context.strokePath()
                }
            case .dots:
                let diameterDevice: Double = 2
                let diameter = diameterDevice / scale
                record.alignedPhaseX = CanvasBackgroundGeometry.alignedPosition(
                    phase.phaseX, backingScale: scale, lineWidthDevice: diameterDevice)
                record.alignedPhaseY = CanvasBackgroundGeometry.alignedPosition(
                    phase.phaseY, backingScale: scale, lineWidthDevice: diameterDevice)
                let path = CGMutablePath()
                let xs = phase.verticalPositions().map {
                    CanvasBackgroundGeometry.alignedPosition($0, backingScale: scale, lineWidthDevice: diameterDevice)
                }
                let ys = phase.horizontalPositions().map {
                    CanvasBackgroundGeometry.alignedPosition($0, backingScale: scale, lineWidthDevice: diameterDevice)
                }
                for x in xs {
                    for y in ys {
                        path.addEllipse(in: CGRect(x: x - diameter / 2, y: y - diameter / 2,
                                                   width: diameter, height: diameter))
                    }
                }
                record.dotCount = xs.count * ys.count
                if !path.isEmpty {
                    record.pathCount = 1
                    context.setFillColor(patternColor)
                    context.addPath(path)
                    context.fillPath()
                }
            }
        }

        qaLastRecord = record
    }

    private func resolvedColor(_ source: CanvasBackgroundColorSource, fallback: SurfaceToken) -> CGColor {
        switch source {
        case .custom(let rgba):
            // EXACT. No token remap, no contrast adjustment, no appearance
            // rewrite — the same bytes in Aqua and in Dark.
            return rgba.cgColor
        case .systemDefault:
            return fallback.color.cgColor(in: self)
        }
    }

    private func rgba8(of color: CGColor) -> [Int] {
        guard let components = color.components, components.count >= 3 else { return [] }
        let alpha = components.count >= 4 ? components[3] : 1
        return [
            Int((components[0] * 255).rounded()),
            Int((components[1] * 255).rounded()),
            Int((components[2] * 255).rounded()),
            Int((alpha * 255).rounded()),
        ]
    }
}
