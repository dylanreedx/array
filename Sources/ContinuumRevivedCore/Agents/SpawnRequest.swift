import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2D.2-detect-spawn-tool-call.md
//
// An orchestrator asks for a worker by CALLING A TOOL (P2D.1's `spawn_agent`
// extension, which is inert by design). Continuum already parses every tool call
// in the Pi stream, so this type is the whole reading half: the observed call's
// arguments, parsed, or nothing.
//
// I5 — WHY THIS IS NOT `Codable`. `PiEventTranslator` deliberately drops tool
// `args` because they are the sensitive half of a tool call (`args.path`, and
// here a model-authored `prompt`). That must stay true for anything crossing the
// sync boundary, so this value is a LOCAL-ONLY side channel: the translator hands
// it to the in-process supervisor and it never enters `AgentRuntimeEvent`, never
// reaches `ManagedAgentActivityBridge`, and cannot be serialized by accident —
// omitting `Codable` makes that a compile-time property rather than a convention.
// `AgentActivityEvent.swift`'s I5 comment states the rule this obeys.
public struct SpawnRequest: Equatable, Sendable {
    /// The ONE tool name whose arguments are read. A whitelist, not a filter on
    /// the arguments' shape: any other tool's args stay dropped, which is what
    /// keeps this from becoming a general "expose tool arguments" channel.
    public static let toolName = "spawn_agent"

    /// Role id matching a `.pi/agents/<role>.md`, when the caller named one.
    public let role: String?
    /// The child's task. Model-authored text: I5-sensitive, local only.
    public let prompt: String
    /// Whether the child gets its own git worktree (P2C.2's isolated spawn).
    public let isolated: Bool

    public init(role: String?, prompt: String, isolated: Bool) {
        self.role = role
        self.prompt = prompt
        self.isolated = isolated
    }

    /// Parses the `args` object of an observed tool call, as JSON text.
    ///
    /// nil for a tool that is not whitelisted, for args that are not a JSON
    /// object, and for a missing or empty `prompt` — a child with no task is not a
    /// spawn worth performing, and defaulting one would invent the work.
    public static func parse(toolName: String, argsJSON: String) -> SpawnRequest? {
        guard let data = argsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return parse(toolName: toolName, args: object)
    }

    /// The already-deserialized form, for `PiEventTranslator` — it has parsed the
    /// stream line and re-encoding the args just to re-parse them would put a
    /// second `JSONSerialization` pass in a per-token path.
    static func parse(toolName: String, args: [String: Any]) -> SpawnRequest? {
        guard toolName == SpawnRequest.toolName else { return nil }
        guard let prompt = args["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        // A blank role is no role: the record's `role` is an id used to find
        // `.pi/agents/<role>.md`, and "" would name a file that cannot exist.
        var role = (args["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if role?.isEmpty == true { role = nil }
        // Optional, and STRICTLY a Bool. A string "true" is not coerced: the
        // extension's schema declares a boolean, so a string means the caller sent
        // something else, and guessing which way to read it would silently put an
        // agent in the shared checkout the flag exists to keep it out of.
        let isolated = (args["isolated"] as? Bool) ?? false
        return SpawnRequest(role: role, prompt: prompt, isolated: isolated)
    }
}
