import Foundation

// Queue 91 / P7: pure Core canvas entity index and spatial query foundation.
// No AppKit, storage, provider transport, tool registration, or UI integration.

public struct CanvasEntityStableID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        precondition(!rawValue.isEmpty, "CanvasEntityStableID must not be empty")
        self.rawValue = rawValue
    }

    public static func agent(_ id: AgentID) -> CanvasEntityStableID { CanvasEntityStableID("agent:\(id.rawValue.uuidString)") }
    public static func tile(_ id: UUID) -> CanvasEntityStableID { CanvasEntityStableID("tile:\(id.uuidString)") }
    public static func zone(_ id: UUID) -> CanvasEntityStableID { CanvasEntityStableID("zone:\(id.uuidString)") }
    public static func artifact(_ namespace: String, _ id: String) -> CanvasEntityStableID { CanvasEntityStableID("artifact:\(namespace):\(id)") }

    public var description: String { rawValue }
    public static func < (lhs: CanvasEntityStableID, rhs: CanvasEntityStableID) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum CanvasEntityKind: Hashable, Sendable, Comparable {
    case agent
    case tile
    case zone
    case note
    case terminal
    case fileTree
    case browser
    case artifact(String)

    public var sortKey: String {
        switch self {
        case .agent: return "agent"
        case .tile: return "tile"
        case .zone: return "zone"
        case .note: return "note"
        case .terminal: return "terminal"
        case .fileTree: return "fileTree"
        case .browser: return "browser"
        case .artifact(let value): return "artifact:\(value)"
        }
    }

    public static func < (lhs: CanvasEntityKind, rhs: CanvasEntityKind) -> Bool { lhs.sortKey < rhs.sortKey }
}

public enum CanvasEntityVisibility: String, Hashable, Codable, Sendable {
    case visible
    case hidden
    case detached
    case deleted
}

public enum CanvasEntityFreshness: Hashable, Codable, Sendable {
    case fresh(observedAt: Date)
    case stale(observedAt: Date, reason: String)

    public var observedAt: Date {
        switch self {
        case .fresh(let observedAt), .stale(let observedAt, _): return observedAt
        }
    }

    public var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    public var evidenceLabel: String {
        switch self {
        case .fresh(let observedAt): return "fresh@\(observedAt.timeIntervalSinceReferenceDate)"
        case .stale(let observedAt, let reason): return "stale(\(reason))@\(observedAt.timeIntervalSinceReferenceDate)"
        }
    }
}

public struct CanvasWorldPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct CanvasWorldRect: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ frame: TileFrame) {
        self.init(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var center: CanvasWorldPoint { CanvasWorldPoint(x: x + width / 2, y: y + height / 2) }

    public func contains(_ point: CanvasWorldPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    public func contains(_ rect: CanvasWorldRect) -> Bool {
        rect.minX >= minX && rect.maxX <= maxX && rect.minY >= minY && rect.maxY <= maxY
    }

    public func overlaps(_ other: CanvasWorldRect) -> Bool {
        minX <= other.maxX && maxX >= other.minX && minY <= other.maxY && maxY >= other.minY
    }

    public func distance(to point: CanvasWorldPoint) -> Double {
        let dx = max(max(minX - point.x, 0), point.x - maxX)
        let dy = max(max(minY - point.y, 0), point.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    public func centerDistance(to point: CanvasWorldPoint) -> Double {
        let dx = center.x - point.x
        let dy = center.y - point.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

public enum CanvasScopeRole: Hashable, Sendable {
    /// Entity can contribute project/directory scope. The optional checkout handle
    /// is opaque; this P7 foundation deliberately does not carry absolute paths.
    case emitsScope(projectId: UUID, relativeWorkingDirectory: String?, checkoutHandle: String?)
    /// Entity can be mentioned/inspected as context but grants no filesystem authority.
    case contextOnly

    public var emitsFilesystemAuthority: Bool {
        if case .emitsScope = self { return true }
        return false
    }
}

public struct CanvasEntity: Hashable, Sendable {
    public let id: CanvasEntityStableID
    public var kind: CanvasEntityKind
    public var label: String
    public var frame: CanvasWorldRect?
    public var visibility: CanvasEntityVisibility
    public var freshness: CanvasEntityFreshness
    public var zoneId: CanvasEntityStableID?
    public var projectId: UUID?
    public var attachedAgentId: AgentID?
    public var scopeRole: CanvasScopeRole
    public var evidence: [String]

    public init(
        id: CanvasEntityStableID,
        kind: CanvasEntityKind,
        label: String,
        frame: CanvasWorldRect?,
        visibility: CanvasEntityVisibility = .visible,
        freshness: CanvasEntityFreshness,
        zoneId: CanvasEntityStableID? = nil,
        projectId: UUID? = nil,
        attachedAgentId: AgentID? = nil,
        scopeRole: CanvasScopeRole = .contextOnly,
        evidence: [String] = []
    ) {
        precondition(kind != .note || !scopeRole.emitsFilesystemAuthority, "notes must never grant filesystem authority")
        precondition(kind != .browser || !scopeRole.emitsFilesystemAuthority, "browser entities must never grant filesystem authority")
        self.id = id
        self.kind = kind
        self.label = label
        self.frame = frame
        self.visibility = visibility
        self.freshness = freshness
        self.zoneId = zoneId
        self.projectId = projectId
        self.attachedAgentId = attachedAgentId
        self.scopeRole = scopeRole
        self.evidence = evidence
    }
}

public struct CanvasEntityQueryOptions: Hashable, Sendable {
    public var includeHidden: Bool
    public var includeDeleted: Bool
    public var includeStale: Bool
    public var includeDetachedAgents: Bool
    public var kinds: Set<CanvasEntityKind>?

    public init(
        includeHidden: Bool = false,
        includeDeleted: Bool = false,
        includeStale: Bool = false,
        includeDetachedAgents: Bool = false,
        kinds: Set<CanvasEntityKind>? = nil
    ) {
        self.includeHidden = includeHidden
        self.includeDeleted = includeDeleted
        self.includeStale = includeStale
        self.includeDetachedAgents = includeDetachedAgents
        self.kinds = kinds
    }

    public static let visibleFresh = CanvasEntityQueryOptions()
    public static let addressable = CanvasEntityQueryOptions(includeHidden: true, includeDeleted: false, includeStale: true, includeDetachedAgents: true)
}

public struct CanvasEntityEvidence: Hashable, Sendable {
    public let entityId: CanvasEntityStableID
    public let kind: CanvasEntityKind
    public let relation: String
    public let distance: Double?
    public let visibility: CanvasEntityVisibility
    public let freshness: String
    public let notes: [String]
}

public enum CanvasEntityResolution: Hashable, Sendable {
    case chosen(CanvasEntityStableID, evidence: [CanvasEntityEvidence])
    case matches([CanvasEntityStableID], evidence: [CanvasEntityEvidence])
    case ambiguous([CanvasEntityStableID], evidence: [CanvasEntityEvidence], reason: String)
    case unavailable(CanvasEntityStableID?, reason: String, evidence: [CanvasEntityEvidence])

    public var chosenIDsSnapshot: CanvasEntityResolutionSnapshot {
        switch self {
        case .chosen(let id, let evidence): return CanvasEntityResolutionSnapshot(entityIds: [id], evidence: evidence)
        case .matches(let ids, let evidence): return CanvasEntityResolutionSnapshot(entityIds: ids, evidence: evidence)
        case .ambiguous(let ids, let evidence, _): return CanvasEntityResolutionSnapshot(entityIds: ids, evidence: evidence)
        case .unavailable(let id, let reason, let evidence):
            return CanvasEntityResolutionSnapshot(entityIds: id.map { [$0] } ?? [], evidence: evidence + [CanvasEntityEvidence(entityId: id ?? CanvasEntityStableID("unavailable:none"), kind: .artifact("unavailable"), relation: reason, distance: nil, visibility: .deleted, freshness: "unavailable", notes: [])])
        }
    }
}

public struct CanvasEntityResolutionSnapshot: Hashable, Sendable {
    public let entityIds: [CanvasEntityStableID]
    public let evidence: [CanvasEntityEvidence]

    public init(entityIds: [CanvasEntityStableID], evidence: [CanvasEntityEvidence]) {
        self.entityIds = entityIds.sorted()
        self.evidence = evidence
    }
}

public enum CanvasDirection: String, Hashable, Codable, Sendable {
    case left
    case right
    case up
    case down
}

public struct CanvasEntityRegistrationReport: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case inserted
        case duplicateRejected(existing: CanvasEntityStableID)
    }

    public let id: CanvasEntityStableID
    public let outcome: Outcome

    public var duplicateEntityID: CanvasEntityStableID? {
        if case .duplicateRejected(let existing) = outcome { return existing }
        return nil
    }
}

public struct CanvasEntityIndex: Sendable {
    private var entitiesByID: [CanvasEntityStableID: CanvasEntity]
    public private(set) var registrationReports: [CanvasEntityRegistrationReport]

    public init(entities: [CanvasEntity]) {
        var map: [CanvasEntityStableID: CanvasEntity] = [:]
        var reports: [CanvasEntityRegistrationReport] = []
        for entity in entities {
            if map[entity.id] != nil {
                reports.append(CanvasEntityRegistrationReport(id: entity.id, outcome: .duplicateRejected(existing: entity.id)))
            } else {
                map[entity.id] = entity
                reports.append(CanvasEntityRegistrationReport(id: entity.id, outcome: .inserted))
            }
        }
        self.entitiesByID = map
        self.registrationReports = reports
    }

    public var duplicateEntityIDs: [CanvasEntityStableID] {
        Array(Set(registrationReports.compactMap(\.duplicateEntityID))).sorted()
    }

    @discardableResult
    public mutating func upsert(_ entity: CanvasEntity) -> CanvasEntityRegistrationReport {
        let report: CanvasEntityRegistrationReport
        if entitiesByID[entity.id] != nil {
            report = CanvasEntityRegistrationReport(id: entity.id, outcome: .duplicateRejected(existing: entity.id))
        } else {
            entitiesByID[entity.id] = entity
            report = CanvasEntityRegistrationReport(id: entity.id, outcome: .inserted)
        }
        registrationReports.append(report)
        return report
    }

    public var allEntities: [CanvasEntity] { sorted(Array(entitiesByID.values)) }

    public func entity(id: CanvasEntityStableID, options: CanvasEntityQueryOptions = .addressable) -> CanvasEntityResolution {
        guard let entity = entitiesByID[id] else { return .unavailable(id, reason: "not-registered", evidence: []) }
        guard isEligible(entity, options: options) else {
            return .unavailable(id, reason: ineligibleReason(entity, options: options), evidence: [evidence(for: entity, relation: "addressability-filtered", distance: nil)])
        }
        return .chosen(id, evidence: [evidence(for: entity, relation: entity.frame == nil ? "addressable-without-visible-geometry" : "addressable", distance: nil)])
    }

    public func contains(point: CanvasWorldPoint, options: CanvasEntityQueryOptions = .visibleFresh) -> CanvasEntityResolution {
        let matches = eligible(options).filter { $0.frame?.contains(point) == true }
        return matchResolution(matches, relation: "contains-point", metric: nil)
    }

    public func contains(rect: CanvasWorldRect, options: CanvasEntityQueryOptions = .visibleFresh) -> CanvasEntityResolution {
        let matches = eligible(options).filter { entity in entity.frame.map { $0.contains(rect) } ?? false }
        return matchResolution(matches, relation: "contains-rect", metric: nil)
    }

    public func overlap(rect: CanvasWorldRect, options: CanvasEntityQueryOptions = .visibleFresh) -> CanvasEntityResolution {
        let matches = eligible(options).filter { entity in entity.frame.map { $0.overlaps(rect) } ?? false }
        return matchResolution(matches, relation: "overlap", metric: nil)
    }

    public func nearest(to point: CanvasWorldPoint, options: CanvasEntityQueryOptions = .visibleFresh) -> CanvasEntityResolution {
        rankedSpatial(options, relation: "nearest") { $0.centerDistance(to: point) }
    }

    public func radius(center: CanvasWorldPoint, radius: Double, options: CanvasEntityQueryOptions = .visibleFresh) -> CanvasEntityResolution {
        let matches = eligible(options).compactMap { entity -> (CanvasEntity, Double)? in
            guard let frame = entity.frame else { return nil }
            let distance = frame.centerDistance(to: center)
            return distance <= radius ? (entity, distance) : nil
        }
        return matchResolution(matches.map(\.0), relation: "radius", metric: { entity in matches.first { $0.0.id == entity.id }?.1 })
    }

    public func directional(from origin: CanvasEntityStableID, direction: CanvasDirection, options: CanvasEntityQueryOptions = .visibleFresh) -> CanvasEntityResolution {
        guard let originEntity = entitiesByID[origin] else { return .unavailable(origin, reason: "origin-not-registered", evidence: []) }
        guard isEligible(originEntity, options: CanvasEntityQueryOptions(includeHidden: true, includeDeleted: false, includeStale: true, includeDetachedAgents: true)), let originFrame = originEntity.frame else {
            return .unavailable(origin, reason: "origin-has-no-visible-geometry", evidence: [evidence(for: originEntity, relation: "origin", distance: nil)])
        }
        let originCenter = originFrame.center
        let candidates = eligible(options).filter { $0.id != origin && $0.frame != nil }.compactMap { entity -> (CanvasEntity, Double)? in
            guard let frame = entity.frame else { return nil }
            let center = frame.center
            switch direction {
            case .left where center.x < originCenter.x:
                return (entity, originCenter.x - center.x + abs(center.y - originCenter.y) / 10_000)
            case .right where center.x > originCenter.x:
                return (entity, center.x - originCenter.x + abs(center.y - originCenter.y) / 10_000)
            case .up where center.y < originCenter.y:
                return (entity, originCenter.y - center.y + abs(center.x - originCenter.x) / 10_000)
            case .down where center.y > originCenter.y:
                return (entity, center.y - originCenter.y + abs(center.x - originCenter.x) / 10_000)
            default:
                return nil
            }
        }
        return ranked(candidates, relation: "directional:\(direction.rawValue)")
    }

    public func sameZone(as origin: CanvasEntityStableID, options: CanvasEntityQueryOptions = .visibleFresh) -> CanvasEntityResolution {
        guard let originEntity = entitiesByID[origin] else { return .unavailable(origin, reason: "origin-not-registered", evidence: []) }
        guard let zoneId = originEntity.zoneId else { return .unavailable(origin, reason: "origin-has-no-zone", evidence: [evidence(for: originEntity, relation: "origin", distance: nil)]) }
        let matches = eligible(options).filter { $0.id != origin && $0.zoneId == zoneId }
        return matchResolution(matches, relation: "same-zone", metric: nil)
    }

    public func sameProject(as origin: CanvasEntityStableID, options: CanvasEntityQueryOptions = .visibleFresh) -> CanvasEntityResolution {
        guard let originEntity = entitiesByID[origin] else { return .unavailable(origin, reason: "origin-not-registered", evidence: []) }
        guard let projectId = originEntity.projectId else { return .unavailable(origin, reason: "origin-has-no-project", evidence: [evidence(for: originEntity, relation: "origin", distance: nil)]) }
        let matches = eligible(options).filter { $0.id != origin && $0.projectId == projectId }
        return matchResolution(matches, relation: "same-project", metric: nil)
    }

    public func validate(snapshot: CanvasEntityResolutionSnapshot, options: CanvasEntityQueryOptions = .addressable) -> CanvasEntityResolution {
        var checked: [CanvasEntityEvidence] = []
        for id in snapshot.entityIds {
            guard let entity = entitiesByID[id] else { return .unavailable(id, reason: "snapshot-target-not-registered", evidence: checked) }
            checked.append(evidence(for: entity, relation: "snapshot-validation", distance: nil))
            guard isEligible(entity, options: options) else { return .unavailable(id, reason: "snapshot-target-\(ineligibleReason(entity, options: options))", evidence: checked) }
        }
        return .matches(snapshot.entityIds, evidence: snapshot.evidence + checked)
    }

    private func eligible(_ options: CanvasEntityQueryOptions) -> [CanvasEntity] {
        sorted(Array(entitiesByID.values)).filter { isEligible($0, options: options) && $0.frame != nil }
    }

    private func isEligible(_ entity: CanvasEntity, options: CanvasEntityQueryOptions) -> Bool {
        if let kinds = options.kinds, !kinds.contains(entity.kind) { return false }
        switch entity.visibility {
        case .visible: break
        case .hidden where options.includeHidden: break
        case .detached where entity.kind == .agent && options.includeDetachedAgents: break
        case .deleted where options.includeDeleted: break
        default: return false
        }
        if entity.freshness.isStale && !options.includeStale { return false }
        return true
    }

    private func ineligibleReason(_ entity: CanvasEntity, options: CanvasEntityQueryOptions) -> String {
        if let kinds = options.kinds, !kinds.contains(entity.kind) { return "kind-filtered" }
        if entity.visibility == .hidden && !options.includeHidden { return "hidden" }
        if entity.visibility == .deleted && !options.includeDeleted { return "deleted" }
        if entity.visibility == .detached && !options.includeDetachedAgents { return "detached" }
        if entity.freshness.isStale && !options.includeStale { return "stale" }
        return "filtered"
    }

    private func rankedSpatial(_ options: CanvasEntityQueryOptions, relation: String, metric: (CanvasWorldRect) -> Double) -> CanvasEntityResolution {
        ranked(eligible(options).compactMap { entity in entity.frame.map { (entity, metric($0)) } }, relation: relation)
    }

    private func ranked(_ candidates: [(CanvasEntity, Double)], relation: String) -> CanvasEntityResolution {
        let sortedCandidates = candidates.sorted { lhs, rhs in
            if abs(lhs.1 - rhs.1) > 0.000_001 { return lhs.1 < rhs.1 }
            return deterministicLess(lhs.0, rhs.0)
        }
        guard let first = sortedCandidates.first else { return .unavailable(nil, reason: "no-eligible-candidates", evidence: []) }
        let tied = sortedCandidates.filter { abs($0.1 - first.1) <= 0.000_001 }
        let evidences = sortedCandidates.map { evidence(for: $0.0, relation: relation, distance: $0.1) }
        if tied.count > 1 {
            return .ambiguous(tied.map { $0.0.id }.sorted(), evidence: evidences, reason: "equal-\(relation)-metric")
        }
        return .chosen(first.0.id, evidence: [evidence(for: first.0, relation: relation, distance: first.1)])
    }

    private func matchResolution(_ matches: [CanvasEntity], relation: String, metric: ((CanvasEntity) -> Double?)?) -> CanvasEntityResolution {
        let sortedMatches = sorted(matches)
        guard !sortedMatches.isEmpty else { return .unavailable(nil, reason: "no-eligible-candidates", evidence: []) }
        return .matches(sortedMatches.map(\.id), evidence: sortedMatches.map { evidence(for: $0, relation: relation, distance: metric?($0)) })
    }

    private func evidence(for entity: CanvasEntity, relation: String, distance: Double?) -> CanvasEntityEvidence {
        CanvasEntityEvidence(entityId: entity.id, kind: entity.kind, relation: relation, distance: distance, visibility: entity.visibility, freshness: entity.freshness.evidenceLabel, notes: entity.evidence.sorted())
    }

    private func sorted(_ entities: [CanvasEntity]) -> [CanvasEntity] {
        entities.sorted(by: deterministicLess)
    }

    private func deterministicLess(_ lhs: CanvasEntity, _ rhs: CanvasEntity) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        return lhs.id < rhs.id
    }
}

public extension CanvasEntityIndex {
    static func tileEntity(
        _ tile: Tile,
        observedAt: Date,
        visibility: CanvasEntityVisibility = .visible,
        projectId: UUID? = nil,
        agentId: AgentID? = nil,
        freshness: CanvasEntityFreshness? = nil,
        scopeRole: CanvasScopeRole? = nil
    ) -> CanvasEntity {
        let kind: CanvasEntityKind
        switch tile.kind {
        case .managedAgent: kind = .tile
        case .terminal: kind = .terminal
        case .note: kind = .note
        case .fileTree: kind = .fileTree
        case .browser, .browserInspector: kind = .browser
        case .runArtifacts: kind = .artifact("runArtifacts")
        default: kind = .tile
        }
        // Canonical identity policy: a visual tile is always registered under
        // its tile ID. A managed-agent tile may carry an attachedAgentId relation,
        // but it must not alias to the stable agent entity when that agent ID is
        // known; detached/authoritative agent records are registered separately.
        let id = CanvasEntityStableID.tile(tile.id)
        let role = scopeRole ?? ((kind == .terminal || kind == .fileTree) && projectId != nil ? .emitsScope(projectId: projectId!, relativeWorkingDirectory: nil, checkoutHandle: nil) : .contextOnly)
        return CanvasEntity(
            id: id,
            kind: kind,
            label: tile.title,
            frame: CanvasWorldRect(tile.frame),
            visibility: visibility,
            freshness: freshness ?? .fresh(observedAt: observedAt),
            zoneId: tile.zoneId.map(CanvasEntityStableID.zone),
            projectId: projectId,
            attachedAgentId: agentId,
            scopeRole: role,
            evidence: ["tile:\(tile.id.uuidString)", "world-frame"]
        )
    }
}
