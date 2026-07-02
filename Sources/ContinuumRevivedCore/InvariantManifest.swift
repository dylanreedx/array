import Foundation

/// A hand-rolled JSON-value tagged union used exclusively as the value type of
/// `InvariantManifest.measurements`. This is the ONLY name for this wrapper in the
/// codebase — there is no "AnyCodable". Kept intentionally minimal: string, int,
/// double, bool, array, null. Nested objects are represented as flat key-path
/// strings at the call site (e.g. "tile_0_id"), never as a nested `.object` case.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSONValue: unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Custom equality: JSON itself has one "number" type, not separate int/double
    /// types, so a whole-number `.double` (e.g. 300.0) and an `.int` (300) are
    /// indistinguishable once serialized to JSON text — `JSONEncoder` writes both as
    /// `300`. Comparing `.int`/`.double` by numeric value (rather than deriving
    /// `Equatable`, which would treat them as different cases) is what makes the
    /// manifest's write-then-read-back-from-disk round trip in `writeAndVerify`
    /// actually hold for real measured values, not just for values that happen to
    /// avoid the ambiguity.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.null, .null): return true
        case (.array(let a), .array(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.int(let a), .double(let b)), (.double(let b), .int(let a)):
            return Double(a) == b
        default: return false
        }
    }
}

/// The outcome of a single invariant check block, written through this enum's
/// `.rawValue` at every call site so a typo cannot ship a wrong value to disk.
public enum InvariantOutcome: String, Sendable {
    case pass
    case stub
    case fail
}

/// Per-run measured-value record for one of the eight structural invariants (I1–I8)
/// that govern the distributed-canvas program. Every field is a measured value —
/// never a bare `{passed: true}`.
public struct InvariantManifest: Codable, Equatable, Sendable {
    public var invariantId: String
    public var runId: String
    public var measuredAt: String
    public var measurements: [String: JSONValue]
    public var outcome: String
    public var failureReason: String?

    public init(
        invariantId: String,
        runId: String,
        measuredAt: String,
        measurements: [String: JSONValue],
        outcome: String,
        failureReason: String? = nil
    ) {
        self.invariantId = invariantId
        self.runId = runId
        self.measuredAt = measuredAt
        self.measurements = measurements
        self.outcome = outcome
        self.failureReason = failureReason
    }
}

/// Writes an `InvariantManifest` to disk as pretty-printed, sorted-key JSON.
public enum InvariantManifestWriter {
    public static func write(_ manifest: InvariantManifest, to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let file = dir.appendingPathComponent("invariant-\(manifest.invariantId)-\(manifest.runId).json")
        try data.write(to: file)
    }
}
