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

    /// claude's spawn verb, under BOTH its names. The tool was renamed `Task` →
    /// `Agent`, and a build in the wild may still be emitting either.
    public static let claudeToolNames = ["Agent", "Task"]

    /// Role id matching a `.pi/agents/<role>.md`, when the caller named one.
    public let role: String?
    /// The child's task. Model-authored text: I5-sensitive, local only.
    public let prompt: String
    /// Whether the child gets its own git worktree (P2C.2's isolated spawn).
    public let isolated: Bool
    /// Opaque provider item identity used only to position the resulting child
    /// milestone beside the tool call that created it.
    public let sourceItemID: String?
    /// The child is the HARNESS's, not Array's.
    ///
    /// A pi or codex `spawn_agent` asks Array to start a process it will own. A
    /// claude `Agent` call reports one claude has ALREADY started inside itself:
    /// Array can watch it and must never claim to run it. That difference is what
    /// decides the child's `AgentCapabilities`, and getting it from the request
    /// rather than from a harness name keeps it true during a migration.
    public let observedOnly: Bool
    /// A short human label for the child, when the caller supplied one.
    ///
    /// claude's `Agent` tool carries `description` beside `prompt` — a few words
    /// the model writes to say what it is delegating ("Research sports news").
    /// It is already whitelisted as publishable on the tool-detail channel, and
    /// it is the only thing in the call that makes a decent tile title. Without
    /// it a child ends up named after its `tool_use` id, which is what shipped
    /// first and looked exactly as bad as it sounds.
    public let displayLabel: String?

    public init(
        role: String?,
        prompt: String,
        isolated: Bool,
        sourceItemID: String? = nil,
        observedOnly: Bool = false,
        displayLabel: String? = nil
    ) {
        self.role = role
        self.prompt = prompt
        self.isolated = isolated
        self.sourceItemID = sourceItemID
        self.observedOnly = observedOnly
        self.displayLabel = displayLabel
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
    static func parse(toolName: String, args: [String: Any], sourceItemID: String? = nil) -> SpawnRequest? {
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
        return SpawnRequest(role: role, prompt: prompt, isolated: isolated, sourceItemID: sourceItemID)
    }

    /// The claude analogue: an `Agent` (formerly `Task`) tool call.
    ///
    /// Claude has already started the child by the time this call appears, so the
    /// result is `observedOnly` and `toolUseID` is REQUIRED — it is the id every
    /// one of that child's frames carries in `parent_tool_use_id`, and therefore
    /// the only stable way to tie the child's work to the call that made it. A
    /// child announcement Array cannot re-identify later is not worth minting.
    ///
    /// `isolation: "worktree"` is claude's spelling of the same `isolated`
    /// semantics pi expresses as a boolean, and it is read as a fact about the
    /// child rather than as an instruction to Array — Array is not making this
    /// worktree.
    public static func parseClaudeAgentTool(
        toolName: String,
        args: [String: Any],
        toolUseID: String
    ) -> SpawnRequest? {
        guard claudeToolNames.contains(toolName) else { return nil }
        guard !toolUseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let prompt = args["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        var role = (args["subagent_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if role?.isEmpty == true { role = nil }
        var label = (args["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if label?.isEmpty == true { label = nil }
        return SpawnRequest(
            role: role,
            prompt: prompt,
            isolated: (args["isolation"] as? String) == "worktree",
            sourceItemID: toolUseID,
            observedOnly: true,
            displayLabel: label)
    }

    /// pi's OTHER delegation verb, from the third-party `harness-agents`
    /// extension the user installs themselves.
    ///
    /// Deliberately not folded into `parse`: `spawn_agent` is Array's own inert
    /// extension, whose tool CALL is the whole API and whose child Array then
    /// starts and owns. `delegate_agent` has already dispatched the child as its
    /// own detached `pi --mode json -p --no-session` process before this call is
    /// even reported, so the child is `observedOnly` — Array can watch it and must
    /// never claim to run it or offer a Stop for it. Blurring the two would put a
    /// composer on a process Array cannot prompt.
    ///
    /// Every argument name differs from `spawn_agent`'s, which is why the existing
    /// parser returns nil for these calls twice over: `agent` not `role`, `task`
    /// not `prompt`, `worktree` not `isolated`.
    ///
    /// `toolUseID` is REQUIRED and is what identifies the child. The `runId` — the
    /// thing that actually names the transcript on disk — only arrives later, on
    /// `tool_execution_end`, and it embeds a timestamp and a random suffix, so it
    /// is not re-derivable and a `runId`-keyed identity would mint a fresh child
    /// on every re-observation.
    ///
    /// `worktree: true` is recorded as a fact about the child, not an instruction:
    /// the extension makes that worktree, not Array.
    public static let piDelegateToolName = "delegate_agent"

    public static func parsePiDelegateTool(
        toolName: String,
        args: [String: Any],
        toolUseID: String
    ) -> SpawnRequest? {
        guard toolName == piDelegateToolName else { return nil }
        guard !toolUseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let task = args["task"] as? String,
              !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        var role = (args["agent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if role?.isEmpty == true { role = nil }
        return SpawnRequest(
            role: role,
            prompt: task,
            // Strictly a Bool, for the same reason `parse` refuses to coerce
            // `isolated`: the schema declares one, so a string means something
            // else was sent.
            isolated: (args["worktree"] as? Bool) ?? false,
            sourceItemID: toolUseID,
            observedOnly: true,
            // The tool has no `description` field, so the child's title comes from
            // its role — "code-scout" reads far better than a `call_…` id, and the
            // ordinal ladder in `resolveDerivedDisplayName` handles collisions.
            displayLabel: role)
    }
}

/// Where an observed pi child's transcript actually lives.
///
/// A `delegate_agent` child does NOT appear on the parent's stream — it runs as
/// its own `pi --mode json -p --no-session` process, and the parent's node
/// process appends that child's stdout to
/// `<cwd>/.pi/agent-runs/<runId>/events.jsonl`. So unlike claude, where the
/// child's frames arrive inline keyed by `parent_tool_use_id`, pi's child has to
/// be read from a file — and the file's name is only known once the tool call
/// completes.
///
/// This is the second half of the identity, delivered separately from the
/// `SpawnRequest` for that reason. `toolUseID` ties it back to the child the
/// request already minted; `runId` says where to read. Local-only and
/// non-Codable, for the same I5 reason `SpawnRequest` is.
public struct ObservedRunHandle: Equatable, Sendable {
    public let toolUseID: String
    public let runId: String

    public init(toolUseID: String, runId: String) {
        self.toolUseID = toolUseID
        self.runId = runId
    }

    /// `runId` becomes a path component, so it is validated as one. Rejects
    /// anything with a separator, a parent reference, a control character, or a
    /// leading dot — a model-adjacent string must never be able to name a
    /// directory outside the run store.
    public static func validated(toolUseID: String, runId: String) -> ObservedRunHandle? {
        let trimmedID = toolUseID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = runId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmed.isEmpty, trimmed.count <= 256 else { return nil }
        guard !trimmed.hasPrefix("."), trimmed != "..", !trimmed.contains("/"), !trimmed.contains("\\") else {
            return nil
        }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return ObservedRunHandle(toolUseID: trimmedID, runId: trimmed)
    }
}

/// What the supervisor hands its runner factory: the record, plus the one fact
/// about it that the record itself cannot carry.
///
/// `spawnDepth` lives here rather than on `AgentRecord` because it is not a
/// property of an agent — it is a property of the agent's position in a tree the
/// supervisor owns, and it changes when a parent is archived. `runnerConfig` is
/// `nonisolated` and pure over one record, while `depth(of:)` walks the
/// supervisor's `records` map on the main actor; this struct is the seam between
/// the two.
///
/// It is a struct rather than a second parameter on the factory closure so that
/// the many `makeRunner: { _ in … }` injections in the checks keep compiling, and
/// only the ones that actually read the record have to change — which the
/// compiler then enumerates exhaustively.
public struct AgentRunnerLaunch: Sendable {
    public let record: AgentRecord
    /// Links from this agent up to a root. 0 for a user-created agent.
    public let spawnDepth: Int

    public init(record: AgentRecord, spawnDepth: Int) {
        self.record = record
        self.spawnDepth = spawnDepth
    }
}

/// A runner that can report one of ITS OWN children's frames, keyed by the tool
/// call that spawned it.
///
/// Refines nothing about `AgentRunning` and widens no event: this is the seam the
/// supervisor uses instead of downcasting to a concrete runner class, so a runner
/// that later gains the capability plugs in without the supervisor learning its
/// name. `ClaudeAgentRunner` already had this exact method.
public protocol SubagentEventObserving: AnyObject {
    func observeSubagentEvents(_ handler: @escaping @Sendable (String, AgentRuntimeEvent) -> Void)
}

/// A runner that can report where an observed child's transcript will be found.
///
/// pi's `delegate_agent` child does not stream on the parent at all — it writes to
/// its own run directory — so its runner reports a location rather than frames.
/// Distinct protocol from `SubagentEventObserving` for that reason: the two are
/// genuinely different mechanisms, and a runner may have either, both, or neither.
public protocol ObservedRunReporting: AnyObject {
    func observeObservedRuns(_ handler: @escaping @Sendable (ObservedRunHandle) -> Void)
}
