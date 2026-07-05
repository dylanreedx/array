import Foundation

// Ticket: docs/38-tickets/61b-canvas-editor.md
//
// A pure fold from the folded spatial state into a render-ready scene. The
// ticket names the input `MaterializedState`, but that struct lives in
// `ContinuumRevivedSync` (the op-log module), which depends on this module —
// not the other way around, so `ContinuumRevivedCore` cannot import it
// without a cyclic target dependency. `MaterializedState` is exactly the pair
// `(CanvasState, WorkspaceDocument)` (see OpLog.swift), so this fold takes
// those two Core-native fields directly; a `ContinuumRevivedSync` caller (the
// `SpatialOpReceiver` consumer) passes `materializedState.canvasState` /
// `.workspaceDocument` — no information is lost, no logic is duplicated.

/// A tile as the canvas renders it: world frame, stacking order, zone
/// membership, and a kind glyph TOKEN (an SF Symbol name — the app layer
/// hands it straight to `Image(systemName:)`; no further token→something
/// translation needed for the glyph, unlike the AgentStatus color tokens).
public struct CanvasSceneTile: Equatable, Sendable, Identifiable {
    public var id: UUID { tileId }
    public var tileId: UUID
    public var title: String
    public var frame: TileFrame
    public var zPosition: FracIndex
    public var zoneId: UUID?
    public var kindGlyphToken: String

    public init(tileId: UUID, title: String, frame: TileFrame, zPosition: FracIndex, zoneId: UUID?, kindGlyphToken: String) {
        self.tileId = tileId
        self.title = title
        self.frame = frame
        self.zPosition = zPosition
        self.zoneId = zoneId
        self.kindGlyphToken = kindGlyphToken
    }
}

/// A zone as the canvas renders it: world frame, stacking order, and a tint
/// TOKEN (`ZonePlacement.color`, already a string token — passed through
/// verbatim; token→SwiftUI `Color` mapping stays in the app layer).
public struct CanvasSceneZone: Equatable, Sendable, Identifiable {
    public var id: UUID { zoneId }
    public var zoneId: UUID
    public var name: String
    public var origin: ZonePoint
    public var size: ZoneSize
    public var tintToken: String
    public var zPosition: FracIndex

    public init(zoneId: UUID, name: String, origin: ZonePoint, size: ZoneSize, tintToken: String, zPosition: FracIndex) {
        self.zoneId = zoneId
        self.name = name
        self.origin = origin
        self.size = size
        self.tintToken = tintToken
        self.zPosition = zPosition
    }
}

/// The renderable canvas: zones back-to-front, tiles back-to-front — never
/// array-order, always the (zPosition, id) sort (ties broken the same way
/// `MaterializedState.resolve`/`WorkspaceDocument.zonesInZOrder` break them).
public struct CanvasScene: Equatable, Sendable {
    public var zones: [CanvasSceneZone]
    public var tiles: [CanvasSceneTile]

    public init(zones: [CanvasSceneZone], tiles: [CanvasSceneTile]) {
        self.zones = zones
        self.tiles = tiles
    }
}

/// The single source of truth for a tile kind's glyph token. Values are SF
/// Symbol names, chosen once here — no prior per-kind glyph mapping existed
/// in the codebase to reuse.
public enum CanvasSceneGlyph {
    public static func token(for kind: TileKind) -> String {
        switch kind {
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .browserInspector: return "wrench.and.screwdriver"
        case .note: return "note.text"
        case .file: return "doc"
        case .fileTree: return "folder"
        case .ticketQueue: return "checklist"
        case .conductorQueue: return "list.bullet.rectangle"
        case .diffReview: return "arrow.triangle.branch"
        case .runArtifacts: return "shippingbox"
        }
    }
}

public enum CanvasSceneProjection {
    /// Zones in `zPosition` order with tint tokens, tiles in `(zPosition, id)`
    /// render order with kind glyph tokens, membership resolved from
    /// `tile.zoneId`, world frames passed through.
    public static func scene(canvasState: CanvasState, workspaceDocument: WorkspaceDocument) -> CanvasScene {
        let zones = workspaceDocument.zonesInZOrder.map { zone in
            CanvasSceneZone(
                zoneId: zone.zoneId,
                name: zone.name,
                origin: zone.origin,
                size: zone.size,
                tintToken: zone.color,
                zPosition: zone.zPosition
            )
        }
        let tiles = canvasState.tiles
            .sorted { lhs, rhs in
                if lhs.zPosition != rhs.zPosition { return lhs.zPosition < rhs.zPosition }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map { tile in
                CanvasSceneTile(
                    tileId: tile.id,
                    title: tile.title,
                    frame: tile.frame,
                    zPosition: tile.zPosition,
                    zoneId: tile.zoneId,
                    kindGlyphToken: CanvasSceneGlyph.token(for: tile.kind)
                )
            }
        return CanvasScene(zones: zones, tiles: tiles)
    }
}
