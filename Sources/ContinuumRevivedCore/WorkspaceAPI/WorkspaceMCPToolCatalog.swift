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
/// MCP adapters must not invent a second canvas contract, and must not describe
/// one twice either: every tool here is decoded from
/// `Resources/PiExtensions/array-workspace-tools.json`, the same file pi's
/// `continuum-workspace-tools.ts` registers its tools from. The App target
/// remains responsible for dispatch, identity and authorization.
public enum WorkspaceMCPToolCatalog {
    public static let fileName = "array-workspace-tools.json"

    public struct Tool: Sendable {
        public let name: String
        public let label: String
        public let description: String
        public let promptSnippet: String
        public let promptGuidelines: [String]
        public let operation: WorkspaceAPIOp
        public let inputSchema: [String: WorkspaceMCPJSON]

        /// What an MCP client shows the model. Pi lifts `promptGuidelines` into
        /// its system prompt; MCP has no such slot, so the same guidelines ride
        /// in the description instead of being dropped.
        public var mcpDescription: String {
            guard !promptGuidelines.isEmpty else { return description }
            return description + "\n\nGuidelines:\n" + promptGuidelines.map { "- " + $0 }.joined(separator: "\n")
        }
    }

    /// The host-op tools, in catalog order. Empty only when the Core resource
    /// bundle is missing — which also leaves pi without the extension's tools.
    public static let tools: [Tool] = {
        guard let url = PiExtensionInstaller.bundledExtensionURL(fileName: fileName),
              let data = try? Data(contentsOf: url),
              let tools = try? decode(data) else { return [] }
        return tools
    }()

    public static func decode(_ data: Data) throws -> [Tool] {
        guard case .object(let root) = try JSONDecoder().decode(WorkspaceMCPJSON.self, from: data),
              case .array(let entries)? = root["tools"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "catalog has no tools array"))
        }
        return try entries.map { entry in
            guard case .object(let fields) = entry,
                  case .string(let name)? = fields["name"],
                  case .string(let label)? = fields["label"],
                  case .string(let opName)? = fields["op"], let operation = WorkspaceAPIOp(rawValue: opName),
                  case .string(let description)? = fields["description"],
                  case .string(let snippet)? = fields["promptSnippet"],
                  case .array(let guidelineValues)? = fields["promptGuidelines"],
                  case .object(let parameters)? = fields["parameters"] else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "malformed catalog tool \(entry.jsonString)"))
            }
            let guidelines = guidelineValues.compactMap { value -> String? in
                if case .string(let text) = value { return text }
                return nil
            }
            return Tool(name: name, label: label, description: description, promptSnippet: snippet,
                        promptGuidelines: guidelines, operation: operation, inputSchema: parameters)
        }
    }

    public static func tool(named name: String) -> Tool? { tools.first { $0.name == name } }

    /// The operations a caller can reach through a tool. `workspace.context`
    /// advertises only these: an operation without a tool is not a capability.
    public static var exposedOperations: Set<WorkspaceAPIOp> { Set(tools.map(\.operation)) }

    // MARK: MCP-only

    /// Served by `array-workspace-mcp` itself, never by the host: it polls
    /// `operation.get` until each child settles, so a long wait never parks the
    /// app's main thread. Pi's twin is `wait_agents` in
    /// `continuum-spawn-agent.ts`, which polls the same spawn-result courier the
    /// host reads for `operation.get`'s `childResult`; the shared name keeps the
    /// shared catalog text ("collect it with wait_agents") true for every harness.
    public static let waitAgentsName = "wait_agents"
    public static let waitAgentsDefaultTimeoutSeconds = 600
    public static let waitAgentsTimeoutRange = 5...3600
    public static let waitAgentsMaxHandles = 16
    public static let waitAgentsDescription =
        "Wait for children you created with array_delegate to finish their current turn, and return each child's final answer, failure or refusal. Pass the operationId values array_delegate returned as handles. Blocks until every child is idle or the timeout passes (default 600 s, max 3600 s), then reports any child still running as running. Read-only.\n\nGuidelines:\n- After array_delegate (or array_message_agent), call wait_agents to collect the result. It blocks for you: never sleep, loop, or message the child to poll.\n- A child marked running when the wait ends is still working in its own tile; wait again rather than delegating again."
    public static let waitAgentsInputSchema: [String: WorkspaceMCPJSON] = [
        "type": .string("object"),
        "properties": .object([
            "handles": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string"), "maxLength": .int(128)]),
                "minItems": .int(1),
                "maxItems": .int(waitAgentsMaxHandles),
                "description": .string("The operationId values array_delegate returned.")
            ]),
            "timeoutSeconds": .object([
                "type": .string("number"),
                "description": .string("How long to wait before returning partial results. Default 600, max 3600.")
            ])
        ]),
        "required": .array([.string("handles")])
    ]

    /// MCP `initialize` instructions. Claude Code shows server instructions to
    /// the model even while it defers the tools themselves behind tool search.
    public static let serverInstructions =
        "This agent runs in a tile on the user's Array canvas. These array_* tools see and manage that canvas: array_workspace_context (who and where you are, what you may do), array_canvas_query, array_open_document, array_find_agent and array_inspect_agent. To run work in another visible tile, call array_delegate — a built-in subagent tool (Agent/Task) runs inside this tile and never creates one. array_delegate accepts optional harness (Claude Code, Codex or Pi) and exact catalogue model; omitted fields inherit, except a different harness uses its own catalogue default. array_message_agent starts a turn on another agent in your project, and wait_agents collects the results of children you delegated. To reach an agent by where it sits (\"the agent to your right\"), match array_canvas_query's tile rectangles with array_find_agent's tileIds. What needs the user's OK depends on their Agent permissions setting: under Free, nothing inside your project asks; under Ask first, the first delegation, message or canvas move asks the user in Array. array_workspace_context lists what you may do now. If your title is wrong or your task has clearly changed, retitle yourself with array_update_agent (nameIntent proactive), but never replace a name the user typed (nameSource user or requested in array_workspace_context); when the user or another agent asks for a rename, use nameIntent requested. For a browser, take a snapshot first and act by ref. Use screenshots only to check visuals. Read errors for the next step; do not fall back to curl or Playwright in the shell. Remote domains and user-owned browsers require separate approval."
}

/// How one host reply becomes an MCP `tools/call` result
/// (`.plans/80-browser-computer-use`, S1).
///
/// A reply may carry ONE picture for the model at `result.image` =
/// `{mimeType, data}` (base64 PNG or JPEG). It leaves as an MCP `image` content
/// item, and is stripped from the text item and `structuredContent` alike: the
/// whole reply is serialized into both, so a picture left in place would reach
/// the model as megabytes of base64 text. What remains says `attached: true`.
/// Measured 2026-10-24: codex 0.163 (exec and app-server) and Claude Code
/// 2.1.307 both show the model an image sent alongside `structuredContent`.
/// The pi bridge applies the same rule in `continuum-workspace-tools.ts`.
public enum WorkspaceMCPToolResult {
    public static let imageMimeTypes: Set<String> = ["image/png", "image/jpeg"]

    public static func make(reply: WorkspaceMCPJSON) -> [String: WorkspaceMCPJSON] {
        var visible = reply
        var picture: (mimeType: String, data: String)?
        if case .object(var fields) = reply,
           case .object(var result)? = fields["result"],
           let candidate = result.removeValue(forKey: "image") {
            if case .object(let image) = candidate,
               case .string(let mimeType)? = image["mimeType"], imageMimeTypes.contains(mimeType),
               case .string(let data)? = image["data"], !data.isEmpty {
                picture = (mimeType, data)
                result["image"] = .object(["mimeType": .string(mimeType), "attached": .bool(true)])
            }
            fields["result"] = .object(result)
            visible = .object(fields)
        }
        var content: [WorkspaceMCPJSON] = [.object(["type": .string("text"), "text": .string(visible.jsonString)])]
        if let picture {
            content.append(.object(["type": .string("image"), "data": .string(picture.data),
                                    "mimeType": .string(picture.mimeType)]))
        }
        var result: [String: WorkspaceMCPJSON] = ["content": .array(content), "structuredContent": visible]
        // Array's structured refusals are tool ERRORS: an MCP client that
        // sees no `isError` reports them to the model as successes.
        if case .object(let fields) = reply, fields["status"] == .string("error") { result["isError"] = .bool(true) }
        return result
    }
}
