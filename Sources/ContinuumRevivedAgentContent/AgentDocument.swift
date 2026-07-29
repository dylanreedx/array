import Foundation

/// Semantic authorship. These cases intentionally do not prescribe a speaker label.
public enum AgentEntryRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case reasoning
    case system
}

/// Where an entry originated, independent of how a provider displays it.
public enum AgentProvenance: Codable, Equatable, Sendable {
    case providerItem(provider: String, itemID: String?)
    case localPrompt(promptID: String?)
    case localNotice(reason: String)
}

/// Lifecycle shared by semantic items such as tools, plans, and requests.
public enum AgentItemStatus: String, Codable, Equatable, Sendable {
    case pending
    case inProgress
    case completed
    case failed
    case cancelled
    case interrupted
}

/// Half-open UTF-8 source offsets in the input that produced a semantic node.
public struct AgentSourceRange: Codable, Equatable, Sendable {
    public var lowerBound: UInt64
    public var upperBound: UInt64

    public init?(lowerBound: UInt64, upperBound: UInt64) {
        guard lowerBound <= upperBound else { return nil }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lowerBound = try container.decode(UInt64.self, forKey: .lowerBound)
        let upperBound = try container.decode(UInt64.self, forKey: .upperBound)
        guard let range = Self(lowerBound: lowerBound, upperBound: upperBound) else {
            throw DecodingError.dataCorruptedError(
                forKey: .upperBound,
                in: container,
                debugDescription: "AgentSourceRange upperBound must not precede lowerBound"
            )
        }
        self = range
    }
}

/// One provider/local item in transcript order.
public struct AgentEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: AgentNodeID
    public var revision: UInt64
    public var role: AgentEntryRole
    public var provenance: AgentProvenance
    public var blocks: [AgentBlock]

    public init(
        id: AgentNodeID,
        revision: UInt64 = 0,
        role: AgentEntryRole,
        provenance: AgentProvenance,
        blocks: [AgentBlock] = []
    ) {
        self.id = id
        self.revision = revision
        self.role = role
        self.provenance = provenance
        self.blocks = blocks
    }
}

/// Immutable-by-value semantic transcript snapshot.
public struct AgentDocument: Codable, Equatable, Sendable {
    public var version: UInt64
    public var entries: [AgentEntry]

    public init(version: UInt64 = 0, entries: [AgentEntry] = []) {
        self.version = version
        self.entries = entries
    }

    /// Identity errors are explicit so a bad projection cannot silently make
    /// renderer reuse position-based again.
    public enum IdentityValidationError: Error, Equatable, Sendable {
        case duplicate(id: AgentNodeID, firstPath: String, secondPath: String)
        case revisionRegressed(id: AgentNodeID, previous: UInt64, current: UInt64, path: String)
        case changedWithoutRevision(id: AgentNodeID, revision: UInt64, path: String)
        case unchangedWithRevisionChange(id: AgentNodeID, previous: UInt64, current: UInt64, path: String)
        case nodeTypeChanged(id: AgentNodeID, path: String)
    }

    /// Validates uniqueness and revision transitions against the previous
    /// snapshot. Source ranges are deliberately excluded from visible equality.
    public func validateIdentityInvariants(previous: AgentDocument? = nil) throws {
        if let previous {
            try previous.validateIdentityInvariants()
        }
        var paths: [AgentNodeID: String] = [:]
        var nodes: [(AgentNodeID, UInt64, String, Bool)] = []

        func visit(block: AgentBlock, path: String) throws {
            if let firstPath = paths[block.id] {
                throw IdentityValidationError.duplicate(id: block.id, firstPath: firstPath, secondPath: path)
            }
            paths[block.id] = path
            nodes.append((block.id, block.revision, path, true))
            for (index, child) in block.children.enumerated() {
                try visit(block: child, path: "\(path).children[\(index)]")
            }
        }

        for (entryIndex, entry) in entries.enumerated() {
            let entryPath = "entries[\(entryIndex)]"
            if let firstPath = paths[entry.id] {
                throw IdentityValidationError.duplicate(id: entry.id, firstPath: firstPath, secondPath: entryPath)
            }
            paths[entry.id] = entryPath
            nodes.append((entry.id, entry.revision, entryPath, false))
            for (blockIndex, block) in entry.blocks.enumerated() {
                try visit(block: block, path: "\(entryPath).blocks[\(blockIndex)]")
            }
        }

        guard let previous else { return }
        let old = previous.indexedNodes()
        for (id, revision, path, isBlock) in nodes {
            guard let oldNode = old[id] else { continue }
            guard revision >= oldNode.revision else {
                throw IdentityValidationError.revisionRegressed(id: id, previous: oldNode.revision, current: revision, path: path)
            }
            let changed: Bool
            if isBlock {
                guard oldNode.isBlock, let oldBlock = previous.block(id: id), let currentBlock = block(id: id) else {
                    throw IdentityValidationError.nodeTypeChanged(id: id, path: path)
                }
                changed = !oldBlock.visibleContentEquals(current: currentBlock)
            } else {
                guard !oldNode.isBlock, let oldEntry = previous.entry(id: id), let currentEntry = entry(id: id) else {
                    throw IdentityValidationError.nodeTypeChanged(id: id, path: path)
                }
                changed = !oldEntry.visibleContentEquals(current: currentEntry)
            }
            if changed {
                do {
                    guard revision == (try AgentNodeRevision.next(current: oldNode.revision, visibleContentChanged: true)) else {
                        throw IdentityValidationError.changedWithoutRevision(id: id, revision: revision, path: path)
                    }
                } catch AgentNodeRevision.Error.overflow {
                    throw IdentityValidationError.changedWithoutRevision(id: id, revision: revision, path: path)
                }
            }
            if !changed && revision != oldNode.revision {
                throw IdentityValidationError.unchangedWithRevisionChange(id: id, previous: oldNode.revision, current: revision, path: path)
            }
        }
    }

    private func indexedNodes() -> [AgentNodeID: (revision: UInt64, isBlock: Bool)] {
        var result: [AgentNodeID: (UInt64, Bool)] = [:]
        func visit(_ block: AgentBlock) {
            result[block.id] = (block.revision, true)
            block.children.forEach(visit)
        }
        for entry in entries {
            result[entry.id] = (entry.revision, false)
            entry.blocks.forEach(visit)
        }
        return result
    }

    private func entry(id: AgentNodeID) -> AgentEntry? { entries.first { $0.id == id } }
    private func block(id: AgentNodeID) -> AgentBlock? {
        func find(_ block: AgentBlock) -> AgentBlock? {
            if block.id == id { return block }
            for child in block.children { if let match = find(child) { return match } }
            return nil
        }
        for entry in entries { for block in entry.blocks { if let match = find(block) { return match } } }
        return nil
    }
}

private extension AgentEntry {
    func visibleContentEquals(current: AgentEntry) -> Bool {
        role == current.role && blocks.count == current.blocks.count && zip(blocks, current.blocks).allSatisfy { $0.visibleContentEquals(current: $1) }
    }
}

private extension AgentBlock {
    func visibleContentEquals(current: AgentBlock) -> Bool {
        kind == current.kind && payload == current.payload && children.count == current.children.count && zip(children, current.children).allSatisfy { $0.visibleContentEquals(current: $1) }
    }
}
