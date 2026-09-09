import Foundation

/// What a harness can do with a `/command`, as observed from the BOUND RUNNER.
///
/// Never derived from `record.harness`. A harness name lies for the whole of a
/// transport migration, when a one-shot runner and a session runner for the same
/// harness are both live in one build; the thing that will actually execute the
/// intent is what gets to declare it.
public struct AgentSessionCommandCapabilities: Equatable, Sendable {
    /// The CLI executes a leading slash ITSELF in the mode Array runs it in,
    /// rather than handing the literal text to the model.
    public var interpretsLeadingSlash: Bool
    /// A session RPC exists that can carry a command as a command — pi's
    /// `compact`/`get_state`, codex app-server's thread methods.
    public var canDelegateCommands: Bool
    /// The command names the harness has told us it knows, or nil before it has
    /// said. claude publishes `slash_commands` on `system/init`; nil means "not
    /// discovered yet", and the baseline catalogue answers instead.
    public var advertisedNames: Set<String>?

    public init(
        interpretsLeadingSlash: Bool,
        canDelegateCommands: Bool,
        advertisedNames: Set<String>? = nil
    ) {
        self.interpretsLeadingSlash = interpretsLeadingSlash
        self.canDelegateCommands = canDelegateCommands
        self.advertisedNames = advertisedNames
    }

    /// `claude -p`, measured 2026-08-24: `/help`, `/status` and `/compact` come
    /// back as `model: "<synthetic>"` with zero input tokens, zero output tokens
    /// and zero cost — no model call happened — and an unknown one answers
    /// "Unknown command: …". claude interprets.
    public static let claudeOneShot = AgentSessionCommandCapabilities(
        interpretsLeadingSlash: true, canDelegateCommands: false)

    /// `codex exec --json` and `pi -p --mode json`, measured the same day: both
    /// sent `/help` to the MODEL, which spent a real paid turn answering
    /// conversationally about what it can help with. Serializing a slash command
    /// into prose on these harnesses is not a neutral fallback — it is a
    /// regression that costs the user a turn and returns a wrong answer.
    public static let oneShotProse = AgentSessionCommandCapabilities(
        interpretsLeadingSlash: false, canDelegateCommands: false)
}

/// How one invocation will actually be executed, or why it cannot be.
public enum AgentCommandExecution: Equatable, Sendable {
    /// Array performs it and authors the reply itself, as a `.system` notice with
    /// `provenance: .localNotice`. It never reaches the CLI as text, so it needs
    /// no new runtime event and puts no pressure on the I5 boundary.
    case arrayOwned
    /// The harness performs it, over a session RPC or its own slash handling, and
    /// the reply is attributed to the harness.
    case harnessDelegated
    /// A genuine user turn: a skill or prompt template expands into a prompt and
    /// is sent as one. Unchanged from today.
    case skillTemplate
    /// Array cannot perform it here. **Disabled with a reason, never degraded
    /// into prose** — see `oneShotProse`.
    case unavailable(reason: String)
}

/// Pure classification of a command invocation. Lives in Core so the composer,
/// the popover and the supervisor all answer the same way.
public enum AgentCommandExecutionPlanner {
    public static func resolve(
        _ descriptor: AgentCommandDescriptor,
        capabilities: AgentSessionCommandCapabilities
    ) -> AgentCommandExecution {
        // A descriptor that is anything other than plainly available stays
        // unavailable and keeps its OWN words for why.
        //
        // `.requiresTrust` used to fall through to the delegation branch. An
        // untrusted `.ts`/`.js` extension is disabled in the picker
        // (`descriptor.isEnabled` is false for every non-`.available` case), so
        // nothing could reach it by clicking — but the classifier is also the
        // answer the supervisor gives for a persisted invocation, and it said
        // "delegate this" for a resource whose whole availability story is
        // "do not load this until the user trusts it".
        switch descriptor.availability {
        case .available:
            break
        case let .unavailable(reason), let .requiresTrust(reason):
            return .unavailable(reason: reason)
        case .unknown:
            return .unavailable(reason: "Array can't tell whether this agent has that command.")
        }
        switch descriptor.surface {
        case .array:
            return .arrayOwned
        case .cli:
            // Already refused today, and correctly: a shell command is not a
            // slash command and Array does not run one on the user's behalf here.
            return .unavailable(reason: "This is a shell command, not something this agent can run.")
        case .skill, .promptTemplate, .providerSlash, .extensionCommand:
            // ONE gate for all four, because they share one transport fact: the
            // text leaves Array with a leading slash and something on the other
            // side has to be the thing that reads it.
            //
            // `.skill`/`.promptTemplate` used to return `.skillTemplate` from
            // above this gate, unconditionally. That was only ever safe because
            // dispatch could not resolve a discovered skill at all — the
            // supervisor looked descriptors up in `allBaselines()`, so a
            // `.codex/skills/foo` or `.pi/prompts/foo` row refused for the wrong
            // reason. Making those rows dispatchable (which they must be) turns
            // that same path into a literal `/foo` handed to a codex or pi model,
            // which is the paid-prose regression this whole classifier exists to
            // prevent. A skill spending a real turn is correct; a skill spending
            // a real turn on a CLI that will not expand it is not.
            let expands = capabilities.canDelegateCommands || capabilities.interpretsLeadingSlash
            guard expands else {
                return .unavailable(
                    reason: "This agent's CLI doesn't run slash commands outside its own terminal.")
            }
            if let advertised = capabilities.advertisedNames {
                let names = [descriptor.name] + descriptor.aliases
                guard names.contains(where: { advertised.contains(Self.bareName($0)) }) else {
                    return .unavailable(reason: "This agent doesn't have that command.")
                }
            }
            // else: nothing discovered yet. The baseline catalogue is the best
            // answer available and refusing on a missing list would disable every
            // command until the first turn had run.
            switch descriptor.surface {
            case .skill, .promptTemplate:
                return .skillTemplate
            default:
                return .harnessDelegated
            }
        }
    }

    /// `slash_commands` entries arrive bare (`"compact"`), sometimes plugin-scoped
    /// (`"some-plugin:review"`), while a descriptor's name may carry the slash.
    static func bareName(_ value: String) -> String {
        var name = value
        if name.hasPrefix("/") { name.removeFirst() }
        return name
    }
}
