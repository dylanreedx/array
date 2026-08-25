import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2D.3-role-registry.md
//
// Roles get a first-class home. Five properties:
//   1. THIS repository's own `.pi/agents` is what the registry reads: the five roles
//      the ticket names are all listed, with the frontmatter they declare on disk.
//   2. A temp directory with two role files — one declaring `name`, one not — lists
//      exactly the first. A `.md` with no frontmatter identity is not a role.
//   3. An unknown id returns nil from `role(id:)` and THROWS from `resolve` — an
//      orchestrator's request for a worker that does not exist may not quietly
//      become a generic one.
//   4. A role's `model`/`reasoning` reach Pi as exactly the flags
//      `HarnessRoleRunBuilder` already builds for the same role. Asserted as
//      agreement between the two paths so they cannot drift apart.
//   5. P0.10's rule holds through roles: a bare model alias in a role file throws
//      rather than being handed to `--model`, which takes a pattern and would fuzzy
//      match it. Same for a `reasoning` level `pi --thinking` does not accept.
//
// Negative tests observed red at exit 1 with the final code are quoted at each
// assertion.
func runRoleRegistryChecks() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // ContinuumRevivedCoreChecks
        .deletingLastPathComponent()          // Sources
        .deletingLastPathComponent()          // repo root

    // MARK: 1 · this repository's real roles

    let registry = RoleRegistry(projectRoot: repoRoot)
    let listed = registry.roles().map(\.id)
    // The five the ticket names. NOT an equality assertion: this repo has since grown
    // to nine role files, and pinning the exact set would make adding a role a matrix
    // failure. The floor is what matters — a registry that finds fewer than the roles
    // it is asked about is broken.
    let ticketRoles = ["code-reviewer", "code-scout", "implementer", "platform-breaker", "qa-reviewer"]
    // Red when `init` looks in the wrong directory (`.pi/roles`):
    // `RoleRegistry: this repository's roles are missing from the registry: [...] — listed []`.
    expect(ticketRoles.allSatisfy(listed.contains),
           "RoleRegistry: this repository's roles are missing from the registry: \(ticketRoles.filter { !listed.contains($0) }) — listed \(listed)")
    expect(listed == listed.sorted(), "RoleRegistry: roles are not in id order: \(listed)")
    guard let scout = registry.role(id: "code-scout") else {
        fputs("FAIL: RoleRegistry: code-scout is not in this repository's registry\n", stderr)
        Foundation.exit(1)
    }
    // Quoted from the file on disk, so a role file edited to a different model makes
    // this check fail rather than pass vacuously.
    expect(scout.model == "openai-codex/gpt-5.5" && scout.reasoning == "low" && scout.tools == "read, grep, find, ls, bash",
           "RoleRegistry: code-scout's frontmatter no longer matches what this check asserts — model \(String(describing: scout.model)), reasoning \(String(describing: scout.reasoning)), tools \(String(describing: scout.tools))")

    // MARK: 2 · a file with no declared `name` is not a role

    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-role-registry-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let agents = temp.appendingPathComponent(RoleRegistry.directoryName, isDirectory: true)
    // Roles are a Pi concept (`.pi/agents/<role>.md`) and `RoleRegistry.resolve`
    // validates a declared model against PI's catalogue, so the fixture must declare
    // a Pi id. Taking it from the ambient `modelOptions` made the fixture depend on
    // the operator's stored harness — under the default (Claude Code) it wrote an
    // `anthropic/*` id that the registry then rejected as unqualified.
    do {
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try """
        ---
        name: fixture-role
        model: \(AgentModelConfig.modelOptions(for: .pi)[1])
        reasoning: high
        tools: read, grep
        ---

        You are a fixture.
        """.write(to: agents.appendingPathComponent("fixture-role.md"), atomically: true, encoding: .utf8)
        // Frontmatter, but no identity: the registry has nothing to resolve from.
        try """
        ---
        model: \(AgentModelConfig.modelOptions(for: .pi)[1])
        ---

        Notes that happen to live in the roles directory.
        """.write(to: agents.appendingPathComponent("nameless.md"), atomically: true, encoding: .utf8)
    } catch {
        fputs("FAIL: RoleRegistry: could not write the role fixtures: \(error)\n", stderr)
        Foundation.exit(1)
    }
    let fixture = RoleRegistry(projectRoot: temp)
    // Red when the `name` requirement is dropped from `init`:
    // `RoleRegistry: the temp fixture lists ["fixture-role", "nameless"], expected only the role that declares a name`.
    expect(fixture.roles().map(\.id) == ["fixture-role"],
           "RoleRegistry: the temp fixture lists \(fixture.roles().map(\.id)), expected only the role that declares a name")
    expect(fixture.role(id: "nameless") == nil, "RoleRegistry: a file with no declared name resolved as a role")

    // MARK: 3 · an unknown id is an error, not a default

    let inherited = AgentModelConfig.Resolution(model: AgentModelConfig.defaultModel, thinking: AgentModelConfig.defaultThinking)
    expect(fixture.role(id: "no-such-role") == nil, "RoleRegistry: an unknown id returned a role")
    // Red when `resolve` falls back to `inheriting` for an unknown id:
    // `RoleRegistry: an unknown role resolved instead of throwing`.
    do {
        _ = try fixture.resolve(roleId: "no-such-role", inheriting: inherited)
        fputs("FAIL: RoleRegistry: an unknown role resolved instead of throwing\n", stderr)
        Foundation.exit(1)
    } catch {
        expect(error as? RoleRegistry.Failure == .unknownRole("no-such-role"),
               "RoleRegistry: an unknown role threw \(error), expected .unknownRole")
    }
    // No role named at all is not an error — that is the inherited case.
    expect((try? fixture.resolve(roleId: nil, inheriting: inherited))
            == RoleRegistry.Resolution(model: inherited.model, thinking: inherited.thinking, toolsArguments: []),
           "RoleRegistry: a spawn naming no role must inherit verbatim and pass no --tools")

    // MARK: 4 · the two paths agree on the flags

    guard let fixtureRole = fixture.role(id: "fixture-role"),
          let resolved = try? fixture.resolve(roleId: "fixture-role", inheriting: inherited) else {
        fputs("FAIL: RoleRegistry: the valid fixture role did not resolve\n", stderr)
        Foundation.exit(1)
    }
    expect(resolved.model == AgentModelConfig.modelOptions(for: .pi)[1] && resolved.thinking == "high",
           "RoleRegistry: the role's own model/reasoning must win over the inherited pair — got \(resolved.model) / \(resolved.thinking)")
    expect(resolved.toolsArguments == ["--tools", "read, grep"],
           "RoleRegistry: the role's tools reached Pi as \(resolved.toolsArguments)")
    // The harness path (a role run in a terminal) and the managed-agent path (a role
    // spawned by the supervisor) must launch Pi with the same three flags for the same
    // role. Red when `resolve` stops reading `role.reasoning`: the pairs differ on
    // `--thinking` and this names both lists.
    let harnessArguments = HarnessRoleRunBuilder.buildLaunchProfile(
        role: fixtureRole, prompt: "task", projectRoot: temp.path, runId: "fixture-run"
    ).arguments
    let agentArguments = PiAgentRunner.processArguments(
        model: resolved.model,
        thinking: resolved.thinking,
        sessionId: "fixture-session",
        extraArgs: resolved.toolsArguments,
        prompt: "task"
    )
    let flagged = ["--model", "--thinking", "--tools"]
    let harnessFlags = flagPairs(in: harnessArguments, flags: flagged)
    let agentFlags = flagPairs(in: agentArguments, flags: flagged)
    expect(harnessFlags.count == flagged.count,
           "RoleRegistry: the harness path passes \(harnessFlags) — the agreement assertion needs all of \(flagged)")
    expect(harnessFlags == agentFlags,
           "RoleRegistry: the harness and managed-agent paths disagree on what this role runs — harness \(harnessFlags), agent \(agentFlags)")

    // MARK: 5 · a role file may not reopen fuzzy model matching (P0.10)

    for (label, field, value, expected) in [
        ("a bare model alias", "model", "gpt-5.5", RoleRegistry.Failure.unqualifiedModel(role: "bad-role", model: "gpt-5.5")),
        ("an unknown thinking level", "reasoning", "ludicrous", RoleRegistry.Failure.unknownReasoning(role: "bad-role", reasoning: "ludicrous")),
    ] {
        let badRoot = temp.appendingPathComponent("bad-\(field)", isDirectory: true)
        let directory = badRoot.appendingPathComponent(RoleRegistry.directoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "---\nname: bad-role\n\(field): \(value)\ntools: read\n---\n\nbody\n"
                .write(to: directory.appendingPathComponent("bad-role.md"), atomically: true, encoding: .utf8)
        } catch {
            fputs("FAIL: RoleRegistry: could not write the \(label) fixture: \(error)\n", stderr)
            Foundation.exit(1)
        }
        let bad = RoleRegistry(projectRoot: badRoot)
        // The role is still LISTED — it exists on disk and the palette shows it. What
        // must not happen is resolving it into flags. Red when the
        // `AgentModelConfig.modelOptions.contains` guard is dropped: `RoleRegistry:
        // \(label) resolved instead of throwing`.
        expect(bad.role(id: "bad-role") != nil, "RoleRegistry: the \(label) fixture was not even listed")
        do {
            _ = try bad.resolve(roleId: "bad-role", inheriting: inherited)
            fputs("FAIL: RoleRegistry: \(label) resolved instead of throwing — \(value) would be handed to Pi\n", stderr)
            Foundation.exit(1)
        } catch {
            // The SPECIFIC failure, not merely "it threw" (cross-review): a typo that
            // made the fixture unparseable would otherwise satisfy this assertion.
            expect(error as? RoleRegistry.Failure == expected,
                   "RoleRegistry: \(label) threw \(error), expected \(expected)")
        }
        // …and the tool list is still readable, because `toolsArguments` is what the
        // runner uses and an unrelated bad field must not quietly widen or narrow what
        // an existing agent may do. Red when `runnerConfig(for:)` goes back through
        // `resolve`: it would resolve to nil here and pass no `--tools` at all.
        expect(bad.toolsArguments(roleId: "bad-role") == ["--tools", "read"],
               "RoleRegistry: \(label) also cost the role its tools: \(bad.toolsArguments(roleId: "bad-role"))")
    }
    expect(fixture.toolsArguments(roleId: "no-such-role").isEmpty && fixture.toolsArguments(roleId: nil).isEmpty,
           "RoleRegistry: an unknown or absent role must pass no --tools")

    try runRoleRegistryHarnessConvergenceChecks()

    print("RoleRegistry checks passed: \(listed.count) roles listed from this repository (all \(ticketRoles.count) the ticket names, code-scout's frontmatter verbatim), a nameless .md excluded, an unknown id nil-and-throwing, no role inheriting verbatim, and the harness/managed-agent paths agreeing on \(harnessFlags.count) flags")
}

/// The `--flag value` pairs a launch argument list carries, for the flags asked about.
/// Order-independent, because the two builders order their flags differently.
private func flagPairs(in arguments: [String], flags: [String]) -> [String: String] {
    var pairs: [String: String] = [:]
    for (index, argument) in arguments.enumerated() where flags.contains(argument) {
        guard index + 1 < arguments.count else { continue }
        pairs[argument] = arguments[index + 1]
    }
    return pairs
}


/// C0b — one role concept, three roots, and the reason pi subagents were dead.
///
/// All three harnesses declare subagent roles as a directory of markdown files
/// with YAML frontmatter and differ only in the dot-dir. And pi's spawn verb was
/// denied to every roled agent because each role file declares a `tools:`
/// allowlist and none of them lists `spawn_agent` — the fourth of four
/// independent reasons pi spawning shipped unreachable.
func runRoleRegistryHarnessConvergenceChecks() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-role-harness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let piModel = AgentModelConfig.modelOptions(for: .pi)[1]
    func writeRole(_ harness: AgentHarness, name: String, tools: String) throws {
        let directory = temp.appendingPathComponent(
            RoleRegistry.directoryName(for: harness), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        model: \(piModel)
        reasoning: high
        tools: \(tools)
        ---
        Body.
        """.write(to: directory.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    }

    try writeRole(.pi, name: "pi-orchestrator", tools: "read, grep")
    try writeRole(.claudeCode, name: "claude-reviewer", tools: "Read, Grep")
    try writeRole(.codex, name: "codex-reader", tools: "read")

    // Each harness reads ITS OWN directory and never another's. A registry that
    // fell back across roots would run a claude role's instructions under pi.
    for (harness, expected, foreign) in [
        (AgentHarness.pi, "pi-orchestrator", "claude-reviewer"),
        (AgentHarness.claudeCode, "claude-reviewer", "codex-reader"),
        (AgentHarness.codex, "codex-reader", "pi-orchestrator"),
    ] {
        let registry = RoleRegistry(projectRoot: temp, harness: harness)
        expect(registry.role(id: expected) != nil,
               "C0b: \(harness.rawValue) must read \(RoleRegistry.directoryName(for: harness))")
        expect(registry.role(id: foreign) == nil,
               "C0b: \(harness.rawValue) must not read another harness's role directory")
    }

    // The default stays pi, so every existing caller keeps its meaning.
    expect(RoleRegistry(projectRoot: temp).role(id: "pi-orchestrator") != nil,
           "C0b: the default harness must remain pi for existing callers")

    // C8(4): the spawn verb is appended by ARRAY, at Array's own depth cap, so a
    // role file never has to track a code-level limit it cannot see.
    let pi = RoleRegistry(projectRoot: temp, harness: .pi)
    expect(pi.toolsArguments(roleId: "pi-orchestrator") == ["--tools", "read, grep"],
           "C8: the default must stay the role's own allowlist, unchanged")
    expect(pi.toolsArguments(roleId: "pi-orchestrator", allowingSpawn: false) == ["--tools", "read, grep"],
           "C8: below the cap the spawn verb must be withheld, not refused later")
    // T5.2 (2026-08-25): pi has TWO delegation verbs and ALL missing ones are
    // appended, not just the first. `spawn_agent` is Array's own bundled
    // extension; `delegate_agent` is a third-party one the user installed. Since
    // `--tools` is a hard allowlist covering extension tools, appending only the
    // first silently denied the other — which is what made pi delegation look
    // broken while Array's own extension was installed and loading correctly.
    expect(pi.toolsArguments(roleId: "pi-orchestrator", allowingSpawn: true)
            == ["--tools", "read, grep, spawn_agent, delegate_agent"],
           "T5.2: a roled pi agent allowed to spawn must be offered BOTH pi delegation verbs")

    // Idempotent, per verb: a role that already lists ONE is given only the other,
    // and keeps its own ordering.
    try writeRole(.pi, name: "pi-spawner", tools: "read, spawn_agent")
    let respawned = RoleRegistry(projectRoot: temp, harness: .pi)
    expect(respawned.toolsArguments(roleId: "pi-spawner", allowingSpawn: true)
            == ["--tools", "read, spawn_agent, delegate_agent"],
           "T5.2: a role already declaring one spawn verb must gain the missing one and not repeat the declared one")
    try writeRole(.pi, name: "pi-both", tools: "read, delegate_agent, spawn_agent")
    let both = RoleRegistry(projectRoot: temp, harness: .pi)
    expect(both.toolsArguments(roleId: "pi-both", allowingSpawn: true)
            == ["--tools", "read, delegate_agent, spawn_agent"],
           "T5.2: a role declaring both verbs must be left exactly as written")

    // A role with no tool list keeps having none: pi's default already includes
    // spawning and inventing a list would NARROW what the agent may do.
    expect(respawned.toolsArguments(roleId: "no-such-role", allowingSpawn: true).isEmpty,
           "C8: an unknown role must still pass no --tools even when spawning is allowed")

    expect(RoleRegistry.spawnToolNames(for: .claudeCode) == ["Agent", "Task"],
           "C0b: claude's spawn verb must be detected under BOTH its current and former name")
    expect(RoleRegistry.spawnToolNames(for: .pi) == ["spawn_agent", "delegate_agent"],
           "T5.2: pi's spawn verbs are Array's own extension AND the third-party delegate_agent")

    print("RoleRegistry harness convergence checks passed: three roots read independently, pi default preserved, and Array's depth cap withholds the spawn verb instead of refusing it")
}
