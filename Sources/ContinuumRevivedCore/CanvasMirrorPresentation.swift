import ContinuumRevivedAgentUI
import Foundation

public enum CanvasMirrorFramingState: Equatable, Sendable {
    case waitingForFirstSnapshot
    case autoFramedFirstSnapshot
    case userControlled
}

public struct CanvasMirrorViewportSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct CanvasMirrorPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct CanvasMirrorRect: Equatable, Sendable, CustomStringConvertible {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }

    public var description: String {
        "CanvasMirrorRect(minX: \(minX), minY: \(minY), maxX: \(maxX), maxY: \(maxY))"
    }

    func union(_ other: CanvasMirrorRect) -> CanvasMirrorRect {
        CanvasMirrorRect(
            minX: Swift.min(minX, other.minX),
            minY: Swift.min(minY, other.minY),
            maxX: Swift.max(maxX, other.maxX),
            maxY: Swift.max(maxY, other.maxY)
        )
    }
}

public struct CanvasMirrorViewport: Equatable, Sendable {
    public var scale: Double
    public var panX: Double
    public var panY: Double

    public init(scale: Double, panX: Double, panY: Double) {
        self.scale = scale
        self.panX = panX
        self.panY = panY
    }
}

public struct CanvasMirrorFramingResult: Equatable, Sendable {
    public var viewport: CanvasMirrorViewport
    public var framingState: CanvasMirrorFramingState

    public init(viewport: CanvasMirrorViewport, framingState: CanvasMirrorFramingState) {
        self.viewport = viewport
        self.framingState = framingState
    }
}

public struct CanvasMirrorFreshnessDisplay: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var asOf: Date?

    public init(title: String, detail: String, asOf: Date?) {
        self.title = title
        self.detail = detail
        self.asOf = asOf
    }
}

public struct CanvasMirrorTileStatus: Equatable, Sendable {
    public var tileId: UUID
    public var status: AgentStatus
    public var summary: String?
    public var updatedAt: Date?

    // P1.8: `presentation` removed with `AgentStatusPresentation` — the phone
    // derives glyph and hue from `status` through `StatusChipPresenter`.
    public init(
        tileId: UUID,
        status: AgentStatus,
        summary: String?,
        updatedAt: Date?
    ) {
        self.tileId = tileId
        self.status = status
        self.summary = summary
        self.updatedAt = updatedAt
    }
}

public struct CanvasMirrorFocusResult: Equatable, Sendable {
    public var viewport: CanvasMirrorViewport
    public var highlightedTileId: UUID?
    public var message: String?

    public init(viewport: CanvasMirrorViewport, highlightedTileId: UUID?, message: String?) {
        self.viewport = viewport
        self.highlightedTileId = highlightedTileId
        self.message = message
    }
}

public struct CanvasMirrorScopeBadge: Equatable, Sendable {
    public var text: String
    public var systemImage: String

    public init(text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }
}

public enum CanvasMirrorPresentation {
    private static let margin: Double = 40
    private static let minScale: Double = 0.05
    private static let maxScale: Double = 3.0
    private static let singleTileMinReadableScale: Double = 0.65
    private static let singleTileMaxReadableScale: Double = 1.2

    public static func workspaceTitle(_ syncedWorkspaceName: String?) -> String {
        let trimmed = syncedWorkspaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Active desktop workspace" : trimmed
    }

    public static func firstSnapshotViewport(
        scene: CanvasScene,
        viewportSize: CanvasMirrorViewportSize,
        current: CanvasMirrorViewport,
        framingState: CanvasMirrorFramingState
    ) -> CanvasMirrorFramingResult {
        guard framingState == .waitingForFirstSnapshot else {
            return CanvasMirrorFramingResult(viewport: current, framingState: framingState)
        }
        guard !scene.zones.isEmpty || !scene.tiles.isEmpty else {
            return CanvasMirrorFramingResult(viewport: current, framingState: .waitingForFirstSnapshot)
        }
        return CanvasMirrorFramingResult(
            viewport: fitAllViewport(scene: scene, viewportSize: viewportSize),
            framingState: .autoFramedFirstSnapshot
        )
    }

    public static func fitAllViewport(scene: CanvasScene, viewportSize: CanvasMirrorViewportSize) -> CanvasMirrorViewport {
        guard let bounds = worldBounds(scene: scene) else {
            return CanvasMirrorViewport(scale: 1, panX: 0, panY: 0)
        }

        let availableWidth = Swift.max(1, viewportSize.width - margin * 2)
        let availableHeight = Swift.max(1, viewportSize.height - margin * 2)
        let rawScale = Swift.min(
            availableWidth / Swift.max(bounds.width, 1),
            availableHeight / Swift.max(bounds.height, 1)
        )
        let scale: Double
        if scene.tiles.count == 1 && scene.zones.isEmpty {
            scale = clamp(rawScale, min: singleTileMinReadableScale, max: singleTileMaxReadableScale)
        } else {
            scale = clamp(rawScale, min: minScale, max: maxScale)
        }
        let panX = (viewportSize.width - bounds.width * scale) / 2 - bounds.minX * scale
        let panY = (viewportSize.height - bounds.height * scale) / 2 - bounds.minY * scale
        return CanvasMirrorViewport(scale: scale, panX: panX, panY: panY)
    }

    public static func showOnCanvas(
        tileId: UUID,
        scene: CanvasScene,
        viewportSize: CanvasMirrorViewportSize,
        currentScale: Double
    ) -> CanvasMirrorFocusResult {
        guard let tile = scene.tiles.first(where: { $0.tileId == tileId }) else {
            return CanvasMirrorFocusResult(
                viewport: CanvasMirrorViewport(scale: clamp(currentScale, min: minScale, max: maxScale), panX: 0, panY: 0),
                highlightedTileId: nil,
                message: "Tile not synced to canvas yet"
            )
        }
        let scale = clamp(currentScale, min: minScale, max: maxScale)
        return CanvasMirrorFocusResult(
            viewport: centeredViewport(frame: tile.frame, viewportSize: viewportSize, scale: scale),
            highlightedTileId: tileId,
            message: nil
        )
    }

    public static func centeredViewport(
        frame: TileFrame,
        viewportSize: CanvasMirrorViewportSize,
        scale: Double
    ) -> CanvasMirrorViewport {
        let center = CanvasMirrorPoint(
            x: frame.x + frame.width / 2,
            y: frame.y + frame.height / 2
        )
        let clampedScale = clamp(scale, min: minScale, max: maxScale)
        return CanvasMirrorViewport(
            scale: clampedScale,
            panX: viewportSize.width / 2 - center.x * clampedScale,
            panY: viewportSize.height / 2 - center.y * clampedScale
        )
    }

    public static func screenCenter(of frame: TileFrame, viewport: CanvasMirrorViewport) -> CanvasMirrorPoint {
        CanvasMirrorPoint(
            x: (frame.x + frame.width / 2) * viewport.scale + viewport.panX,
            y: (frame.y + frame.height / 2) * viewport.scale + viewport.panY
        )
    }

    public static func projectedBounds(scene: CanvasScene, viewport: CanvasMirrorViewport) -> CanvasMirrorRect {
        guard let bounds = worldBounds(scene: scene) else {
            return CanvasMirrorRect(minX: 0, minY: 0, maxX: 0, maxY: 0)
        }
        return CanvasMirrorRect(
            minX: bounds.minX * viewport.scale + viewport.panX,
            minY: bounds.minY * viewport.scale + viewport.panY,
            maxX: bounds.maxX * viewport.scale + viewport.panX,
            maxY: bounds.maxY * viewport.scale + viewport.panY
        )
    }

    public static func freshnessDisplay(
        freshness: CompanionFreshness,
        hasCanvasData: Bool,
        spatialSample: CompanionFreshnessSample?,
        activitySample: CompanionFreshnessSample?,
        now: Date,
        policy: CompanionFreshnessPolicy = CompanionFreshnessPolicy()
    ) -> CanvasMirrorFreshnessDisplay {
        guard hasCanvasData else {
            switch freshness.state {
            case .unpaired:
                return CanvasMirrorFreshnessDisplay(title: "Pair this phone", detail: "Connect to your Continuum instance", asOf: nil)
            default:
                return CanvasMirrorFreshnessDisplay(title: "Waiting for desktop canvas", detail: "No desktop canvas snapshot has arrived", asOf: nil)
            }
        }

        if case .offline(let lastFreshAt, _) = freshness.state {
            return CanvasMirrorFreshnessDisplay(title: "Offline", detail: "Showing cached canvas", asOf: lastFreshAt)
        }
        if case .desktopSleeping(let lastFreshAt) = freshness.state {
            return CanvasMirrorFreshnessDisplay(title: "Mac asleep", detail: "Showing cached canvas", asOf: lastFreshAt)
        }

        let spatialFreshAt = spatialSample?.metadata.publishedAt
        let activityFreshAt = activitySample?.metadata.publishedAt
        let spatialIsLive = spatialFreshAt.map { now.timeIntervalSince($0) <= policy.liveWindow } ?? false
        let activityIsLive = activityFreshAt.map { now.timeIntervalSince($0) <= policy.liveWindow } ?? false
        if spatialFreshAt != nil && !spatialIsLive && activityIsLive {
            return CanvasMirrorFreshnessDisplay(title: "Canvas stale · Agents live", detail: "Showing cached canvas", asOf: spatialFreshAt)
        }

        switch freshness.state {
        case .live(let lastFreshAt) where spatialIsLive:
            return CanvasMirrorFreshnessDisplay(title: "Live", detail: "Desktop canvas current", asOf: lastFreshAt)
        case .live(let lastFreshAt):
            return CanvasMirrorFreshnessDisplay(title: "Live", detail: freshness.subtitle, asOf: spatialFreshAt ?? lastFreshAt)
        case .syncing:
            return CanvasMirrorFreshnessDisplay(title: "Syncing…", detail: "Updating desktop canvas", asOf: spatialFreshAt)
        case .stale(let lastFreshAt):
            return CanvasMirrorFreshnessDisplay(title: "Stale", detail: "Showing cached canvas", asOf: spatialFreshAt ?? lastFreshAt)
        case .unpaired:
            return CanvasMirrorFreshnessDisplay(title: "Pair this phone", detail: "Connect to your Continuum instance", asOf: nil)
        case .desktopSleeping, .offline:
            return CanvasMirrorFreshnessDisplay(title: freshness.title, detail: "Showing cached canvas", asOf: freshness.lastFreshAt)
        }
    }

    public static func statusOverlays(scene: CanvasScene, rows: [AgentsBoardRow]) -> [UUID: CanvasMirrorTileStatus] {
        // P2A.8: a row is keyed by its agent, so the canvas join goes through the optional
        // tile hint — a headless row simply contributes no overlay — via the one shared
        // rule in `keyedByTileHint`.
        let rowsByTile = keyedByTileHint(rows.map { (agentId: $0.agentId, tileId: $0.tileId, value: $0) })
        var result: [UUID: CanvasMirrorTileStatus] = [:]
        for tile in scene.tiles where result[tile.tileId] == nil {
            if let row = rowsByTile[tile.tileId] {
                result[tile.tileId] = CanvasMirrorTileStatus(
                    tileId: tile.tileId,
                    status: row.status,
                    summary: row.lastSummary,
                    updatedAt: row.updatedAt
                )
                continue
            }
            result[tile.tileId] = CanvasMirrorTileStatus(
                tileId: tile.tileId,
                status: .stale,
                summary: nil,
                updatedAt: nil
            )
        }
        return result
    }

    public static func scopeBadge(
        grantedScope: Scope,
        freshness: CompanionFreshness,
        operatorOverrideActive: Bool
    ) -> CanvasMirrorScopeBadge? {
        if operatorOverrideActive {
            return CanvasMirrorScopeBadge(text: "Operator", systemImage: "slider.horizontal.3")
        }
        if !CanvasEditIntent.isEditingPermitted(scope: grantedScope) {
            return CanvasMirrorScopeBadge(text: "View only", systemImage: "lock.fill")
        }
        if !freshness.allowsMutations, let actionBlocker = freshness.actionBlocker {
            return CanvasMirrorScopeBadge(text: actionBlocker, systemImage: "lock.fill")
        }
        return nil
    }

    private static func worldBounds(scene: CanvasScene) -> CanvasMirrorRect? {
        let zoneRects = scene.zones.map {
            CanvasMirrorRect(
                minX: $0.origin.x,
                minY: $0.origin.y,
                maxX: $0.origin.x + $0.size.width,
                maxY: $0.origin.y + $0.size.height
            )
        }
        let tileRects = scene.tiles.map {
            CanvasMirrorRect(
                minX: $0.frame.x,
                minY: $0.frame.y,
                maxX: $0.frame.x + $0.frame.width,
                maxY: $0.frame.y + $0.frame.height
            )
        }
        let rects = zoneRects + tileRects
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    private static func clamp(_ value: Double, min minimum: Double, max maximum: Double) -> Double {
        Swift.min(maximum, Swift.max(minimum, value))
    }
}
