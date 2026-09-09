import Foundation

public enum WorkspaceMCPJSON: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: WorkspaceMCPJSON])
    case array([WorkspaceMCPJSON])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: WorkspaceMCPJSON].self) { self = .object(v) }
        else if let v = try? c.decode([WorkspaceMCPJSON].self) { self = .array(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid MCP JSON") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var jsonString: String {
        guard let data = try? JSONEncoder().encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Provider-neutral MCP projection of the host-owned workspace API.
///
/// MCP adapters must not invent a second canvas contract. This catalog is the
/// shared description surface for native Claude/Codex adapters; the App target
/// remains responsible for dispatch, identity and authorization.
public enum WorkspaceMCPToolCatalog {
    public struct Tool: Sendable {
        public let name: String
        public let description: String
        public let operation: WorkspaceAPIOp
        public let inputSchema: [String: WorkspaceMCPJSON]

        public init(name: String, description: String, operation: WorkspaceAPIOp, inputSchema: [String: WorkspaceMCPJSON]) {
            self.name = name
            self.description = description
            self.operation = operation
            self.inputSchema = inputSchema
        }
    }

    public static let tools: [Tool] = [
        Tool(
            name: "array_workspace_context",
            description: "Return the authoritative Array identity, checkout, workspace, zone, tile, revision, hydration coverage, capabilities, and recent operation outcomes for this agent.",
            operation: .workspaceContext,
            inputSchema: objectSchema(properties: [:])),
        Tool(
            name: "array_open_document",
            description: "Open or reveal a checkout-relative document as an Array canvas tile. Never edits the file; returns the actual tile identity and presentation result.",
            operation: .artifactOpen,
            inputSchema: objectSchema(properties: [
                "relativePath": stringSchema(),
                "checkoutHandle": stringSchema(),
                "artifactHandle": stringSchema(),
                "mode": enumSchema(["openOrReveal", "revealOnly"]),
                "line": integerSchema(minimum: 1),
                "idempotencyKey": stringSchema(maxLength: 128)
            ], required: [])),
        Tool(
            name: "array_canvas_query",
            description: "List the zones and tiles in the authorized Array canvas with world rectangles, structural revision, and hydration coverage. Unhydrated zones do not prove emptiness.",
            operation: .canvasQuery,
            inputSchema: objectSchema(properties: [
                "zoneId": stringSchema(),
                "limit": integerSchema(minimum: 1, maximum: 50),
                "cursor": stringSchema(),
                "checkoutHandle": stringSchema()
            ], required: [])),
        Tool(
            name: "array_canvas_apply",
            description: "Move or resize exactly one authorized Array canvas tile in world coordinates. Query immediately before applying and pass the returned expectedRevision. The first mutation requires user approval.",
            operation: .canvasApply,
            inputSchema: objectSchema(properties: [
                "op": enumSchema(["move", "resize"]),
                "tileId": stringSchema(),
                "worldFrame": frameSchema(),
                "origin": pointSchema(),
                "size": sizeSchema(),
                "expectedRevision": .object(objectSchema(properties: [
                    "epoch": stringSchema(),
                    "structure": integerSchema()
                ], required: ["epoch", "structure"])),
                "idempotencyKey": stringSchema(maxLength: 128)
            ], required: ["op", "tileId", "expectedRevision"])),
    ]

    public static func tool(named name: String) -> Tool? { tools.first { $0.name == name } }

    private static func objectSchema(
        properties: [String: WorkspaceMCPJSON],
        required: [String] = []
    ) -> [String: WorkspaceMCPJSON] {
        var object: [String: WorkspaceMCPJSON] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false)
        ]
        if !required.isEmpty { object["required"] = .array(required.map(WorkspaceMCPJSON.string)) }
        return object
    }

    private static func stringSchema(maxLength: Int? = nil) -> WorkspaceMCPJSON {
        var value: [String: WorkspaceMCPJSON] = ["type": .string("string")]
        if let maxLength { value["maxLength"] = .int(maxLength) }
        return .object(value)
    }

    private static func integerSchema(minimum: Int? = nil, maximum: Int? = nil) -> WorkspaceMCPJSON {
        var value: [String: WorkspaceMCPJSON] = ["type": .string("integer")]
        if let minimum { value["minimum"] = .int(minimum) }
        if let maximum { value["maximum"] = .int(maximum) }
        return .object(value)
    }

    private static func enumSchema(_ values: [String]) -> WorkspaceMCPJSON {
        .object(["type": .string("string"), "enum": .array(values.map(WorkspaceMCPJSON.string))])
    }

    private static func pointSchema() -> WorkspaceMCPJSON {
        .object(objectSchema(properties: ["x": .object(["type": .string("number")]), "y": .object(["type": .string("number")])], required: ["x", "y"]))
    }

    private static func sizeSchema() -> WorkspaceMCPJSON {
        .object(objectSchema(properties: ["width": .object(["type": .string("number")]), "height": .object(["type": .string("number")])], required: ["width", "height"]))
    }

    private static func frameSchema() -> WorkspaceMCPJSON {
        .object(objectSchema(properties: [
            "x": .object(["type": .string("number")]),
            "y": .object(["type": .string("number")]),
            "width": .object(["type": .string("number")]),
            "height": .object(["type": .string("number")])
        ], required: ["x", "y", "width", "height"]))
    }
}
