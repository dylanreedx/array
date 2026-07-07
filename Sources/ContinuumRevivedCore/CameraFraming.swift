import CoreGraphics
import Foundation

public enum CameraFraming {
    public static let mostlyVisibleAreaRatio = 0.75
    public static let tilePaddingScreenPx = 64.0
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

    public static func jumpViewport(
        for worldRect: CGRect,
        kind: TileKind,
        currentViewport: CanvasViewport,
        viewportSize: CGSize
    ) -> CanvasViewport {
        let readableZoom = minimumReadableZoom(for: kind)
        let currentZoom = min(max(currentViewport.zoom, minJumpZoom), maxJumpZoom)
        let mostlyVisible = currentViewport.zoom >= readableZoom
            && mostlyVisibleAreaRatio(worldRect: worldRect, viewport: currentViewport, viewportSize: viewportSize) >= mostlyVisibleAreaRatio
        if mostlyVisible { return currentViewport }

        let targetZoom = currentViewport.zoom >= readableZoom ? currentZoom : min(max(readableZoom, minJumpZoom), maxJumpZoom)
        return readableRevealViewport(for: worldRect, viewportSize: viewportSize, zoom: targetZoom)
    }

    private static func readableRevealViewport(
        for worldRect: CGRect,
        viewportSize: CGSize,
        zoom: Double
    ) -> CanvasViewport {
        let paddedAvailableW = max(Double(viewportSize.width) - 2 * tilePaddingScreenPx, 1)
        let paddedAvailableH = max(Double(viewportSize.height) - 2 * tilePaddingScreenPx, 1)
        let screenW = Double(worldRect.width) * zoom
        let screenH = Double(worldRect.height) * zoom

        // If the whole tile fits at the readable zoom, center it. If not, keep
        // the readable zoom and reveal the top/left useful area with padding
        // instead of zooming terminals/browsers down into an unreadable overview.
        let originX: Double
        if screenW <= paddedAvailableW {
            originX = Double(worldRect.midX) - Double(viewportSize.width) / 2 / zoom
        } else {
            originX = Double(worldRect.minX) - tilePaddingScreenPx / zoom
        }

        let originY: Double
        if screenH <= paddedAvailableH {
            originY = Double(worldRect.midY) - Double(viewportSize.height) / 2 / zoom
        } else {
            originY = Double(worldRect.minY) - tilePaddingScreenPx / zoom
        }

        return CanvasViewport(x: originX, y: originY, zoom: zoom)
    }
}
