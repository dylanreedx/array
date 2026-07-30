import Foundation

/// Codable/Sendable JSON-shaped storage for provider data that has no semantic
/// type yet. It deliberately cannot hold `Any`, closures, or platform objects.
///
/// The custom Codable representation is the JSON value itself, rather than
/// Swift's synthesized enum-case envelope. This preserves an extension's
/// object/array/scalar shape when an unknown node crosses a document boundary.
public indirect enum AgentOpaqueValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([AgentOpaqueValue])
    case object([String: AgentOpaqueValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AgentOpaqueValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AgentOpaqueValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "opaque provider payload must be a JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

public struct AgentOpaquePayload: Codable, Equatable, Sendable {
    /// A diagnostic name preserved for inspection tools. It is opaque data and
    /// is intentionally not included in user-facing fallback text.
    public var debugLabel: String
    public var value: AgentOpaqueValue

    public init(debugLabel: String, value: AgentOpaqueValue) {
        self.debugLabel = debugLabel
        self.value = value
    }
}

public extension AgentBlock {
    /// Safe text for the unregistered-renderer fallback. Only the validated
    /// semantic kind is allowlisted; neither the label nor payload is rendered.
    var safeFallbackSummary: String {
        "Unsupported content: \(kind.rawValue)"
    }

    /// VoiceOver receives the same deliberately payload-free description.
    var safeFallbackAccessibilityLabel: String {
        safeFallbackSummary
    }

    /// Opaque blocks acquire actions only when their kind has an explicit
    /// renderer. The fallback itself is always passive.
    func allowsInteraction(rendererRegistered: Bool) -> Bool {
        guard case .opaque = payload else { return true }
        return rendererRegistered
    }
}
