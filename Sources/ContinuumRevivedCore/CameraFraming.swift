import CoreGraphics
import Foundation

public enum CameraFraming {
    public static let mostlyVisibleAreaRatio = 0.75
    public static let tilePaddingScreenPx = 64.0
    /// Screen-space band of surrounding canvas a reveal/work framing tries to
    /// keep around the tile. Wider than `tilePaddingScreenPx` on purpose: its
    /// job is CONTEXT (a gap-adjacent neighbor's edge stays on screen), not
    /// merely "the tile isn't flush against the window edge". Only the no-op
    /// rule reads it — composition centers the tile, which yields at least this
    /// much gutter whenever the geometry allows.
    public static let contextGutterScreenPx = 96.0
    public static let minJumpZoom = 0.25
    public static let maxJumpZoom = 1.25
    public static let finalViewportEpsilonScreenPx = 0.5
    public static let zonePaddingScreenPx = 96.0
    public static let zoneMinOverviewZoom = 0.20
    public static let zoneMaxOverviewZoom = 0.80

    public static func minimumReadableZoom(for kind: TileKind) -> Double {
        switch kind {
        case .note: return 0.60
        case .browser, .browserInspector: return 0.70
        case .terminal: return 0.85
        case .file, .fileTree, .diffReview, .ticketQueue, .conductorQueue, .runArtifacts, .managedAgent:
            return 0.70
        }
    }

    public static func editableTargetZoom(for kind: TileKind) -> Double {
        switch kind {
        case .note: return 0.85
        case .browser, .browserInspector: return 0.90
        case .terminal: return 0.95
        case .file, .fileTree, .diffReview, .ticketQueue, .conductorQueue, .runArtifacts, .managedAgent:
            return 0.90
        }
    }

    public static func mostlyVisibleAreaRatio(worldRect: CGRect, viewport: CanvasViewport, viewportSize: CGSize) -> Double {
        let screenRect = CanvasEngine.tileScreenFrame(
            TileFrame(x: worldRect.minX, y: worldRect.minY, width: worldRect.width, height: worldRect.height),
            viewport: viewport
        )
        guard screenRect.width > 0, screenRect.height > 0 else { return 0 }
        let visible = screenRect.intersection(CGRect(origin: .zero, size: viewportSize))
        guard !visible.isNull else { return 0 }
        return Double((visible.width * visible.height) / (screenRect.width * screenRect.height))
    }

    public static func zoneOverviewViewport(for zoneRect: CGRect, viewportSize: CGSize) -> CanvasViewport {
        CanvasEngine.fit(
            worldRect: zoneRect,
            viewportSize: viewportSize,
            padding: zonePaddingScreenPx,
            range: zoneMinOverviewZoom ... zoneMaxOverviewZoom
        )
    }

    /// The camera for REVEALING a tile to WORK in it — the second of the two
    /// keyboard camera modes (`zoneOverviewViewport` is the first). Framing a
    /// tile means putting it at the kind's editable working zoom, not merely at
    /// the readable threshold: a jump lands you somewhere you can type.
    ///
    /// The no-op rule is deliberately strict. "Already 75% on screen at readable
    /// zoom" leaves a tile clipped by the window edge with no surrounding
    /// context, which is the state this camera mode exists to fix, so the
    /// viewport is preserved ONLY when the tile is already at working zoom AND
    /// sits entirely inside the context gutter. Everything else recomposes —
    /// idempotently, so re-activating a revealed tile never drifts.
    public static func revealWorkViewport(
        for worldRect: CGRect,
        kind: TileKind,
        currentViewport: CanvasViewport,
        viewportSize: CGSize
    ) -> CanvasViewport {
        let workingZoom = editableTargetZoom(for: kind)
        if currentViewport.zoom >= workingZoom - 0.0001,
           isComposedForWork(worldRect: worldRect, viewport: currentViewport, viewportSize: viewportSize) {
            return currentViewport
        }
        // Never zoom OUT to reveal: a user already closer than the kind's
        // working zoom keeps their scale (clamped to the jump range).
        let targetZoom = min(max(max(currentViewport.zoom, workingZoom), minJumpZoom), maxJumpZoom)
        return revealWorkComposition(for: worldRect, viewportSize: viewportSize, zoom: targetZoom)
    }

    /// True when the tile's screen frame sits entirely inside the viewport inset
    /// by `contextGutterScreenPx` — the composition reveal/work aims for. A tile
    /// that is merely "mostly visible" is NOT composed for work.
    public static func isComposedForWork(
        worldRect: CGRect,
        viewport: CanvasViewport,
        viewportSize: CGSize
    ) -> Bool {
        let screenRect = CanvasEngine.tileScreenFrame(
            TileFrame(x: worldRect.minX, y: worldRect.minY, width: worldRect.width, height: worldRect.height),
            viewport: viewport
        )
        guard screenRect.width > 0, screenRect.height > 0 else { return false }
        let gutter = CGRect(origin: .zero, size: viewportSize).insetBy(
            dx: CGFloat(contextGutterScreenPx),
            dy: CGFloat(contextGutterScreenPx)
        )
        guard gutter.width > 0, gutter.height > 0 else { return false }
        return gutter.contains(screenRect)
    }

    private static func revealWorkComposition(
        for worldRect: CGRect,
        viewportSize: CGSize,
        zoom: Double
    ) -> CanvasViewport {
        let screenW = Double(worldRect.width) * zoom
        let screenH = Double(worldRect.height) * zoom

        // Whatever fits at working zoom is centered, so the surrounding canvas
        // (and therefore a gap-adjacent neighbor's edge) stays visible on both
        // sides. An axis that CANNOT fit keeps working zoom anyway and reveals
        // the useful top/left area with padding, rather than shrinking a
        // terminal or browser down into an unusable overview.
        let originX: Double
        if screenW <= Double(viewportSize.width) {
            originX = Double(worldRect.midX) - Double(viewportSize.width) / 2 / zoom
        } else {
            originX = Double(worldRect.minX) - tilePaddingScreenPx / zoom
        }

        let originY: Double
        if screenH <= Double(viewportSize.height) {
            originY = Double(worldRect.midY) - Double(viewportSize.height) / 2 / zoom
        } else {
            originY = Double(worldRect.minY) - tilePaddingScreenPx / zoom
        }

        return CanvasViewport(x: originX, y: originY, zoom: zoom)
    }
}
