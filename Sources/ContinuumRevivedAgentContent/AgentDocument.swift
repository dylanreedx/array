import Foundation

/// Stable semantic identity. The projection/reconciliation layers choose the value;
/// views and source offsets never do.
public struct AgentNodeID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 512,
              !rawValue.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let id = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "AgentNodeID must be nonempty, bounded, and contain no control characters"
            )
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

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
}
