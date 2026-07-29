import Foundation

/// Stable-ID changes produced by exactly one successful document mutation.
/// Arrays are sorted by ID so equivalent reducer outcomes have identical patch
/// order regardless of lookup-table iteration order.
public struct AgentDocumentPatch: Equatable, Sendable {
    public let fromVersion: UInt64
    public let toVersion: UInt64
    public let inserted: [AgentNodeID]
    public let updated: [AgentNodeID]
    public let removed: [AgentNodeID]
    public let moved: [AgentNodeID]

    public enum Section: String, Equatable, Sendable {
        case inserted
        case updated
        case removed
        case moved
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case versionDidNotAdvanceExactlyOnce(from: UInt64, to: UInt64)
        case duplicateID(section: Section, id: AgentNodeID)
        case contradictoryStructuralChange(id: AgentNodeID, first: Section, second: Section)
    }

    public init(
        fromVersion: UInt64,
        toVersion: UInt64,
        inserted: [AgentNodeID] = [],
        updated: [AgentNodeID] = [],
        removed: [AgentNodeID] = [],
        moved: [AgentNodeID] = []
    ) throws {
        guard fromVersion < UInt64.max, toVersion == fromVersion + 1 else {
            throw ValidationError.versionDidNotAdvanceExactlyOnce(from: fromVersion, to: toVersion)
        }

        let inserted = try Self.validated(inserted, section: .inserted)
        let updated = try Self.validated(updated, section: .updated)
        let removed = try Self.validated(removed, section: .removed)
        let moved = try Self.validated(moved, section: .moved)

        // A moved node may also have updated visible content. Structural states
        // are otherwise mutually exclusive: a node cannot be inserted,
        // removed, or moved in two different ways in one minimal patch.
        try Self.rejectOverlap(inserted, .inserted, removed, .removed)
        try Self.rejectOverlap(inserted, .inserted, moved, .moved)
        try Self.rejectOverlap(removed, .removed, moved, .moved)
        try Self.rejectOverlap(inserted, .inserted, updated, .updated)
        try Self.rejectOverlap(removed, .removed, updated, .updated)

        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.inserted = inserted
        self.updated = updated
        self.removed = removed
        self.moved = moved
    }

    /// A semantic no-op still represents one accepted mutation and therefore
    /// advances the document version, but contains no node-level instructions.
    public static func empty(fromVersion: UInt64) throws -> Self {
        guard fromVersion < UInt64.max else {
            throw ValidationError.versionDidNotAdvanceExactlyOnce(from: fromVersion, to: fromVersion)
        }
        return try Self(fromVersion: fromVersion, toVersion: fromVersion + 1)
    }

    public var isEmpty: Bool {
        inserted.isEmpty && updated.isEmpty && removed.isEmpty && moved.isEmpty
    }

    private static func validated(_ ids: [AgentNodeID], section: Section) throws -> [AgentNodeID] {
        var seen: Set<AgentNodeID> = []
        for id in ids where !seen.insert(id).inserted {
            throw ValidationError.duplicateID(section: section, id: id)
        }
        return ids.sorted { $0.rawValue < $1.rawValue }
    }

    private static func rejectOverlap(
        _ firstIDs: [AgentNodeID],
        _ first: Section,
        _ secondIDs: [AgentNodeID],
        _ second: Section
    ) throws {
        let overlap = Set(firstIDs).intersection(secondIDs).sorted { $0.rawValue < $1.rawValue }
        if let id = overlap.first {
            throw ValidationError.contradictoryStructuralChange(id: id, first: first, second: second)
        }
    }
}
