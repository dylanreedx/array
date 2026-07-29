import Foundation

/// Stable semantic identity. The projection/reconciliation layers choose the
/// stable scope and key; views, source offsets, and current array positions do not.
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

    /// Allocates a deterministic child ID from a stable key. The key is not an
    /// offset or array index, so reparsing the same provider item can reuse it.
    /// Derived IDs reserve space for their deterministic suffix; unusually
    /// long provider scopes remain valid IDs but are not valid child scopes.
    public static let maxDerivedScopeBytes = 320
    public static let maxStableKeyBytes = 128

    public func childID(stableKey: String) -> AgentNodeID? {
        guard rawValue.utf8.count <= Self.maxDerivedScopeBytes,
              !stableKey.isEmpty,
              stableKey.utf8.count <= Self.maxStableKeyBytes,
              !stableKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return Self(rawValue: "\(rawValue)/child-key:\(Self.encodedKey(stableKey))")
    }

    /// A reconciler-owned ordinal allocator. Once a key receives an ordinal,
    /// later allocations cannot change it when other children are inserted.
    public struct ChildAllocator: Codable, Equatable, Sendable {
        public let scope: AgentNodeID
        private var ordinals: [String: UInt64]
        private var nextOrdinal: UInt64

        public init?(scope: AgentNodeID) {
            guard scope.rawValue.utf8.count <= AgentNodeID.maxDerivedScopeBytes else { return nil }
            self.scope = scope
            self.ordinals = [:]
            self.nextOrdinal = 0
        }

        private enum CodingKeys: String, CodingKey { case scope, ordinals, nextOrdinal }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let scope = try container.decode(AgentNodeID.self, forKey: .scope)
            guard let bounded = Self(scope: scope) else {
                throw DecodingError.dataCorruptedError(forKey: .scope, in: container, debugDescription: "child scope exceeds derived-ID bound")
            }
            let ordinals = try container.decode([String: UInt64].self, forKey: .ordinals)
            let nextOrdinal = try container.decode(UInt64.self, forKey: .nextOrdinal)
            let values = Array(ordinals.values)
            guard Set(values).count == values.count,
                  (values.max().map { nextOrdinal > $0 } ?? (nextOrdinal == 0))
            else {
                throw DecodingError.dataCorruptedError(forKey: .ordinals, in: container, debugDescription: "child allocator ordinals must be unique and below nextOrdinal")
            }
            guard ordinals.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= AgentNodeID.maxStableKeyBytes && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
                throw DecodingError.dataCorruptedError(forKey: .ordinals, in: container, debugDescription: "child allocator keys must be stable bounded strings")
            }
            self = bounded
            self.ordinals = ordinals
            self.nextOrdinal = nextOrdinal
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(scope, forKey: .scope)
            try container.encode(ordinals, forKey: .ordinals)
            try container.encode(nextOrdinal, forKey: .nextOrdinal)
        }

        public var assignedKeys: Set<String> { Set(ordinals.keys) }

        public mutating func id(for stableKey: String) -> AgentNodeID? {
            guard !stableKey.isEmpty,
                  stableKey.utf8.count <= AgentNodeID.maxStableKeyBytes,
                  !stableKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            if let ordinal = ordinals[stableKey] {
                return Self.makeID(scope: scope, ordinal: ordinal)
            }
            let ordinal = nextOrdinal
            guard ordinal < UInt64.max else { return nil }
            ordinals[stableKey] = ordinal
            nextOrdinal += 1
            return Self.makeID(scope: scope, ordinal: ordinal)
        }

        private static func makeID(scope: AgentNodeID, ordinal: UInt64) -> AgentNodeID? {
            AgentNodeID(rawValue: "\(scope.rawValue)/child:\(ordinal)")
        }
    }
}

/// Revision policy shared by reducers and reconciliation checks.
public enum AgentNodeRevision {
    public enum Error: Swift.Error, Equatable, Sendable { case overflow }

    public static func next(current: UInt64, visibleContentChanged: Bool) throws -> UInt64 {
        guard visibleContentChanged else { return current }
        guard current < UInt64.max else { throw Error.overflow }
        return current + 1
    }
}

private extension AgentNodeID {
    static func encodedKey(_ key: String) -> String {
        Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
