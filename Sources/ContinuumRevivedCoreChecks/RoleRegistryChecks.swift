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
func runRoleRegistryChecks() {
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
    do {
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try """
        ---
        name: fixture-role
        model: \(AgentModelConfig.modelOptions[1])
        reasoning: high
        tools: read, grep
        ---

        You are a fixture.
        """.write(to: agents.appendingPathComponent("fixture-role.md"), atomically: true, encoding: .utf8)
        // Frontmatter, but no identity: the registry has nothing to resolve from.
        try """
        ---
        model: \(AgentModelConfig.modelOptions[1])
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
    expect(resolved.model == AgentModelConfig.modelOptions[1] && resolved.thinking == "high",
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
