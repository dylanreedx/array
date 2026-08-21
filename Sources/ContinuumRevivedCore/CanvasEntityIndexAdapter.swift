import Foundation

// Queue 91 / P7 live snapshot adapter foundation.
//
// This file deliberately accepts pure values instead of AppKit views, stores,
// WorkspaceRuntime, AgentRecord, or host paths. The adapter's job is only to
// project a live canvas snapshot into the existing deterministic
// CanvasEntityIndex vocabulary.

public struct CanvasEntityIndexSnapshot: Sendable, Equatable {
    public var observedAt: Date
    public var freshness: CanvasEntityFreshness
    public var zones: [CanvasEntityIndexZoneSnapshot]
    public var tiles: [CanvasEntityIndexTileSnapshot]
    public var agents: [CanvasEntityIndexAgentSnapshot]

    public init(
        observedAt: Date,
        freshness: CanvasEntityFreshness? = nil,
        zones: [CanvasEntityIndexZoneSnapshot] = [],
        tiles: [CanvasEntityIndexTileSnapshot] = [],
        agents: [CanvasEntityIndexAgentSnapshot] = []
    ) {
        self.observedAt = observedAt
        self.freshness = freshness ?? .fresh(observedAt: observedAt)
        self.zones = zones
        self.tiles = tiles
        self.agents = agents
    }
}

public struct CanvasEntityIndexZoneSnapshot: Sendable, Equatable {
    public var id: UUID
    public var label: String
    public var frame: CanvasWorldRect?
    public var projectId: UUID?
    public var visibility: CanvasEntityVisibility
    /// Collapsed zones do not remove their tiles from the index; they hide the
    /// contained tile geometry from default spatial queries while leaving it
    /// addressable with `includeHidden`.
    public var isCollapsed: Bool
    public var freshness: CanvasEntityFreshness?

    public init(
        id: UUID,
        label: String,
        frame: CanvasWorldRect? = nil,
        projectId: UUID? = nil,
        visibility: CanvasEntityVisibility = .visible,
        isCollapsed: Bool = false,
        freshness: CanvasEntityFreshness? = nil
    ) {
        self.id = id
        self.label = label
        self.frame = frame
        self.projectId = projectId
        self.visibility = visibility
        self.isCollapsed = isCollapsed
        self.freshness = freshness
    }
}

public struct CanvasEntityIndexTileSnapshot: Sendable, Equatable {
    public var id: UUID
    public var kind: CanvasEntityIndexTileKind
    public var label: String
    /// Already in canvas world coordinates. The adapter performs no viewport,
    /// zoom, or AppKit-coordinate conversion.
    public var worldFrame: CanvasWorldRect
    public var visibility: CanvasEntityVisibility
    public var zoneId: UUID?
    public var projectId: UUID?
    public var relativeWorkingDirectory: String?
    public var checkoutHandle: String?
    public var attachedAgentId: AgentID?
    public var freshness: CanvasEntityFreshness?

    public init(
        id: UUID,
        kind: CanvasEntityIndexTileKind,
        label: String,
        worldFrame: CanvasWorldRect,
        visibility: CanvasEntityVisibility = .visible,
        zoneId: UUID? = nil,
        projectId: UUID? = nil,
        relativeWorkingDirectory: String? = nil,
        checkoutHandle: String? = nil,
        attachedAgentId: AgentID? = nil,
        freshness: CanvasEntityFreshness? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.worldFrame = worldFrame
        self.visibility = visibility
        self.zoneId = zoneId
        self.projectId = projectId
        self.relativeWorkingDirectory = relativeWorkingDirectory
        self.checkoutHandle = checkoutHandle
        self.attachedAgentId = attachedAgentId
        self.freshness = freshness
    }
}

public enum CanvasEntityIndexTileKind: String, Codable, Sendable, Hashable, Comparable {
    case terminal
    case fileTree
    case file
    case note
    case browser
    case managedAgent
    case runArtifacts
    case tile

    public static func < (lhs: CanvasEntityIndexTileKind, rhs: CanvasEntityIndexTileKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var entityKind: CanvasEntityKind {
        switch self {
        case .terminal: return .terminal
        case .fileTree: return .fileTree
        case .note: return .note
        case .browser: return .browser
        case .file: return .file
        case .managedAgent, .tile: return .tile
        case .runArtifacts: return .artifact("runArtifacts")
        }
    }
}

public struct CanvasEntityIndexAgentSnapshot: Sendable, Equatable {
    public var id: AgentID
    public var label: String
    /// Stable visual associations only. These are tile IDs, not identity aliases.
    public var associatedTileIds: [UUID]
    public var projectId: UUID?
    public var relativeWorkingDirectory: String?
    public var checkoutHandle: String?
    public var visibility: CanvasEntityVisibility
    public var freshness: CanvasEntityFreshness?

    public init(
        id: AgentID,
        label: String,
        associatedTileIds: [UUID] = [],
        projectId: UUID? = nil,
        relativeWorkingDirectory: String? = nil,
        checkoutHandle: String? = nil,
        visibility: CanvasEntityVisibility = .detached,
        freshness: CanvasEntityFreshness? = nil
    ) {
        self.id = id
        self.label = label
        self.associatedTileIds = associatedTileIds
        self.projectId = projectId
        self.relativeWorkingDirectory = relativeWorkingDirectory
        self.checkoutHandle = checkoutHandle
        self.visibility = visibility
        self.freshness = freshness
    }
}

public enum CanvasEntityIndexSnapshotAdapter {
    public static func buildIndex(from snapshot: CanvasEntityIndexSnapshot) -> CanvasEntityIndex {
        CanvasEntityIndex(entities: entities(from: snapshot))
    }

    public static func entities(from snapshot: CanvasEntityIndexSnapshot) -> [CanvasEntity] {
        let collapsedOrHiddenZones = Set(snapshot.zones.filter { $0.isCollapsed || $0.visibility != .visible }.map(\.id))
        let zones = snapshot.zones.enumerated().map { ordinal, zone in
            OrderedEntity(ordinal: ordinal, entity: zoneEntity(zone, fallbackFreshness: snapshot.freshness))
        }
        let zoneCount = zones.count
        let tiles = snapshot.tiles.enumerated().map { ordinal, tile in
            OrderedEntity(
                ordinal: zoneCount + ordinal,
                entity: tileEntity(
                    tile,
                    fallbackFreshness: snapshot.freshness,
                    forceHiddenBecauseZone: tile.zoneId.map { collapsedOrHiddenZones.contains($0) } ?? false
                )
            )
        }
        let tileCount = tiles.count
        let agents = snapshot.agents.enumerated().map { ordinal, agent in
            OrderedEntity(ordinal: zoneCount + tileCount + ordinal, entity: agentEntity(agent, fallbackFreshness: snapshot.freshness))
        }
        return (zones + tiles + agents)
            .sorted { lhs, rhs in
                if lhs.entity.kind != rhs.entity.kind { return lhs.entity.kind < rhs.entity.kind }
                if lhs.entity.id != rhs.entity.id { return lhs.entity.id < rhs.entity.id }
                return lhs.ordinal < rhs.ordinal
            }
            .map(\.entity)
    }

    private struct OrderedEntity: Sendable {
        var ordinal: Int
        var entity: CanvasEntity
    }

    private static func zoneEntity(_ zone: CanvasEntityIndexZoneSnapshot, fallbackFreshness: CanvasEntityFreshness) -> CanvasEntity {
        CanvasEntity(
            id: .zone(zone.id),
            kind: .zone,
            label: safeLabel(zone.label, fallback: "Zone"),
            frame: zone.frame,
            visibility: zone.visibility,
            freshness: zone.freshness ?? fallbackFreshness,
            projectId: zone.projectId,
            scopeRole: .contextOnly,
            evidence: ["live-snapshot", "zone:", zone.isCollapsed ? "collapsed" : "expanded"].filter { !$0.isEmpty }
        )
    }

    private static func tileEntity(
        _ tile: CanvasEntityIndexTileSnapshot,
        fallbackFreshness: CanvasEntityFreshness,
        forceHiddenBecauseZone: Bool
    ) -> CanvasEntity {
        let entityKind = tile.kind.entityKind
        let scopeRole: CanvasScopeRole
        if entityKind == .terminal || entityKind == .fileTree || entityKind == .file {
            if let projectId = tile.projectId {
                scopeRole = .emitsScope(
                    projectId: projectId,
                    relativeWorkingDirectory: safeRelative(tile.relativeWorkingDirectory),
                    checkoutHandle: safeOpaqueHandle(tile.checkoutHandle)
                )
            } else {
                scopeRole = .contextOnly
            }
        } else {
            scopeRole = .contextOnly
        }
        return CanvasEntity(
            id: .tile(tile.id),
            kind: entityKind,
            label: safeLabel(tile.label, fallback: "Tile"),
            frame: tile.worldFrame,
            visibility: forceHiddenBecauseZone && tile.visibility == .visible ? .hidden : tile.visibility,
            freshness: tile.freshness ?? fallbackFreshness,
            zoneId: tile.zoneId.map(CanvasEntityStableID.zone),
            projectId: tile.projectId,
            attachedAgentId: tile.attachedAgentId,
            scopeRole: scopeRole,
            evidence: tileEvidence(tile, forceHiddenBecauseZone: forceHiddenBecauseZone)
        )
    }

    private static func agentEntity(_ agent: CanvasEntityIndexAgentSnapshot, fallbackFreshness: CanvasEntityFreshness) -> CanvasEntity {
        let scopeRole: CanvasScopeRole
        if let projectId = agent.projectId {
            scopeRole = .emitsScope(
                projectId: projectId,
                relativeWorkingDirectory: safeRelative(agent.relativeWorkingDirectory),
                checkoutHandle: safeOpaqueHandle(agent.checkoutHandle)
            )
        } else {
            scopeRole = .contextOnly
        }
        return CanvasEntity(
            id: .agent(agent.id),
            kind: .agent,
            label: safeLabel(agent.label, fallback: "Agent"),
            frame: nil,
            visibility: agent.visibility,
            freshness: agent.freshness ?? fallbackFreshness,
            projectId: agent.projectId,
            attachedAgentId: agent.id,
            scopeRole: scopeRole,
            evidence: ["live-snapshot", "agent:", agent.associatedTileIds.map { "tile:\($0.uuidString)" }.sorted().joined(separator: ",")].filter { !$0.isEmpty }
        )
    }

    private static func tileEvidence(_ tile: CanvasEntityIndexTileSnapshot, forceHiddenBecauseZone: Bool) -> [String] {
        var evidence = ["live-snapshot", "tile:\(tile.id.uuidString)", "world-frame"]
        if forceHiddenBecauseZone { evidence.append("zone-collapsed-or-hidden") }
        if safeRelative(tile.relativeWorkingDirectory) == nil, tile.relativeWorkingDirectory != nil { evidence.append("relative-scope-dropped") }
        if safeOpaqueHandle(tile.checkoutHandle) == nil, tile.checkoutHandle != nil { evidence.append("checkout-handle-dropped") }
        return evidence.sorted()
    }

    private static func safeLabel(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !trimmed.contains("://"),
              !trimmed.split(whereSeparator: { $0.isWhitespace }).contains(where: { token in
                  token.hasPrefix("/") || token.hasPrefix("~/") ||
                      token.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
              }),
              !trimmed.split(separator: "/").contains("..") else {
            return fallback
        }
        return trimmed
    }

    private static func safeRelative(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard !value.hasPrefix("/"), !value.hasPrefix("~"), !value.contains("://") else { return nil }
        guard !value.split(separator: "/").contains("..") else { return nil }
        return value
    }

    private static func safeOpaqueHandle(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard !value.hasPrefix("/"), !value.hasPrefix("~"), !value.contains("://") else { return nil }
        return value
    }
}
