import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2D.3-role-registry.md
//
// Roles already existed as files on disk (`.pi/agents/<id>.md`) and
// `HarnessRoleParser` already read their frontmatter. What was missing was a
// HOME for them: discovery lived inline in the AppDelegate, so nothing outside a
// running app could ask "what roles does this project have, and what does role X
// run with?". This is that promotion — no new parsing, no new frontmatter keys.
//
// I5: a role ID is safe to publish (it is a project-authored token, and the
// inbox will show it). A role FILE PATH is not — it names the host's filesystem.
// So `Resolution` carries the flags Pi needs and nothing that quotes a path,
// while `HarnessRole.promptPath` stays behind `roles()`/`role(id:)` for the local
// callers that launch a process with it.
public struct RoleRegistry: Sendable {
    /// Where a project keeps its roles, relative to its root. The same directory
    /// `HarnessRoleRunBuilder` runs `--system-prompt` out of.
    ///
    /// Kept as pi's path because every existing caller means pi; a harness-aware
    /// caller asks `directoryName(for:)` instead.
    public static let directoryName = ".pi/agents"

    /// All three harnesses declare subagent roles the same way — a directory of
    /// markdown files with YAML frontmatter — and differ only in which dot-dir
    /// they read. That is one concept with three roots, not three integrations.
    ///
    /// codex additionally accepts `.toml` role files and `[agents.<name>]` blocks
    /// in `config.toml`; neither is parsed here, and a codex project that uses
    /// only those reports no roles rather than guessing at them.
    public static func directoryName(for harness: AgentHarness) -> String {
        switch harness {
        case .pi: return ".pi/agents"
        case .claudeCode: return ".claude/agents"
        case .codex: return ".codex/agents"
        }
    }

    /// The tool a harness exposes for spawning a subagent. claude renamed `Task`
    /// to `Agent`, so detection must accept both — which is exactly why Array's
    /// tool-detail whitelist is key-driven rather than tool-driven.
    public static func spawnToolNames(for harness: AgentHarness) -> [String] {
        switch harness {
        case .pi: return ["spawn_agent"]
        case .claudeCode: return ["Agent", "Task"]
        case .codex: return ["spawn_agent"]
        }
    }

    private let ordered: [HarnessRole]
    private let byID: [String: HarnessRole]
    private let harness: AgentHarness

    /// Scans `<projectRoot>/.pi/agents/*.md` once, at init.
    ///
    /// A `.md` file with no frontmatter `name` is NOT a role: the registry's whole
    /// job is to answer from frontmatter, and a file that declares none is a note
    /// that happens to live in the directory. `HarnessRoleParser` alone is more
    /// permissive (it falls back to a display name derived from the filename), so
    /// the requirement is applied here rather than by loosening the parser other
    /// callers share.
    public init(projectRoot: URL, harness: AgentHarness = .pi, fileManager: FileManager = .default) {
        self.harness = harness
        let directory = projectRoot.appendingPathComponent(
            RoleRegistry.directoryName(for: harness), isDirectory: true)
        let declared = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .map(\.path)
            .filter { HarnessRoleParser.frontmatter(path: $0)["name"] != nil }
        ordered = HarnessRoleParser.parse(roleFilePaths: declared)
        byID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Every role this project defines, ordered by id (`HarnessRoleParser`'s order).
    public func roles() -> [HarnessRole] { ordered }

    /// The named role, or nil — an unknown id is never a near-match.
    public func role(id: String) -> HarnessRole? { byID[id] }

    /// `["--tools", <list>]` for the named role, or empty — for the role's tool list
    /// ALONE, with no opinion about its model or reasoning. Kept separate from
    /// `resolve` (from the cross-review) so a provider-metadata typo in a role file
    /// cannot silently change what an already-spawned agent is allowed to do: an
    /// unknown role, or one that names no tools, is what Pi ran with before roles
    /// carried a list.
    public func toolsArguments(roleId: String?) -> [String] {
        toolsArguments(roleId: roleId, allowingSpawn: false)
    }

    /// `allowingSpawn` is C8's fix for the reason pi subagents were unreachable
    /// even once the extension loaded: **all twelve `.pi/agents/*.md` roles declare
    /// a `tools:` allowlist and none lists `spawn_agent`**, so the tool was denied
    /// for every roled agent. Appending it here rather than hand-editing twelve
    /// markdown files is deliberate — those files would then have to stay in sync
    /// with a code-level depth cap they cannot see.
    ///
    /// The caller passes `allowingSpawn: depth < maxSpawnDepth`, so **Array's cap
    /// is the binding one and the model is never offered a verb it cannot use.**
    /// That is the same shape as withholding claude's `Agent` tool with
    /// `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`: better than refusing after the fact,
    /// because the model never proposes what it cannot have.
    ///
    /// A role that declares NO tool list is left alone: pi's default is not ours
    /// to invent, and it already includes spawning.
    public func toolsArguments(roleId: String?, allowingSpawn: Bool) -> [String] {
        guard let roleId, let tools = byID[roleId]?.tools else { return [] }
        guard allowingSpawn, let spawnTool = RoleRegistry.spawnToolNames(for: harness).first else {
            return ["--tools", tools]
        }
        let declared = tools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !declared.contains(spawnTool) else { return ["--tools", tools] }
        return ["--tools", (declared + [spawnTool]).joined(separator: ", ")]
    }

    /// What a role runs with: the flags an agent started for it must carry.
    public struct Resolution: Equatable, Sendable {
        public let model: String
        public let thinking: String
        /// `["--tools", <list>]`, or empty when the role names no tool list — Pi's
        /// default is not ours to invent.
        public let toolsArguments: [String]

        public init(model: String, thinking: String, toolsArguments: [String]) {
            self.model = model
            self.thinking = thinking
            self.toolsArguments = toolsArguments
        }
    }

    /// Why a role could not be resolved. Carries the offending values FOR THE LOCAL
    /// LOG only — the caller surfacing a refusal to an agent's transcript must not
    /// interpolate one (see `AgentSupervisor.SpawnRefusal`).
    public enum Failure: Error, Equatable {
        case unknownRole(String)
        /// A `model:` that is not a fully-qualified id in `AgentModelConfig`.
        case unqualifiedModel(role: String, model: String)
        /// A `reasoning:` that is not a level `pi --thinking` accepts.
        case unknownReasoning(role: String, reasoning: String)
    }

    /// Resolves a spawn's role to the flags it runs with.
    ///
    /// `nil` names no role, so `inheriting` is used verbatim — that is the caller's
    /// existing behaviour (a child inherits its parent's provider settings). A role
    /// id that is NOT defined in this project throws: silently falling back would
    /// run a worker the orchestrator did not ask for, which is the one outcome the
    /// ticket rules out.
    ///
    /// A role's own `model`/`reasoning` win over `inheriting` when it declares them,
    /// and each is checked against `AgentModelConfig` first: `--model` takes a
    /// PATTERN, so a bare alias in a role file would re-open the fuzzy matching
    /// P0.10 closed, and an unrecognized `--thinking` level fails the run at Pi.
    public func resolve(roleId: String?, inheriting fallback: AgentModelConfig.Resolution) throws -> Resolution {
        guard let roleId else {
            return Resolution(model: fallback.model, thinking: fallback.thinking, toolsArguments: [])
        }
        guard let role = byID[roleId] else { throw Failure.unknownRole(roleId) }
        var model = fallback.model
        if let declared = role.model {
            guard AgentModelConfig.modelOptions(for: .pi).contains(declared) else {
                throw Failure.unqualifiedModel(role: roleId, model: declared)
            }
            model = declared
        }
        var thinking = fallback.thinking
        if let declared = role.reasoning {
            guard AgentModelConfig.thinkingOptions.contains(declared) else {
                throw Failure.unknownReasoning(role: roleId, reasoning: declared)
            }
            thinking = declared
        }
        return Resolution(model: model, thinking: thinking, toolsArguments: toolsArguments(roleId: role.id))
    }
}
