import ContinuumRevivedCore
import Foundation

/// B5 — a command Array cannot perform is DISABLED WITH A REASON, never
/// degraded into prose.
///
/// The rule used to be the opposite: `AgentSupervisor.accept`'s
/// `.providerCommand` refused only `surface == .cli`, then serialized
/// `nativeSlashText` and sent it as an ordinary user turn. Probing all three CLIs
/// on 2026-08-24 showed what that costs:
///
/// - **claude** interprets a leading slash headlessly — a synthetic reply with
///   zero input tokens, zero output tokens and zero cost, and "Unknown command:
///   …" for one it does not have. Serializing is doing real work there.
/// - **codex** and **pi** send the literal text to the MODEL. Both spent a real,
///   paid turn answering conversationally about what they can help with. On those
///   two, today's fallback is a regression, not a neutral default.
///
/// So the classifier is per-harness and the capability comes from the BOUND
/// RUNNER, never from a harness name — a name lies for the whole of a transport
/// migration, when one-shot and session runners for the same harness are both
/// live in one build.
func runAgentCommandExecutionPlannerChecks() throws {
    func descriptor(
        _ name: String,
        surface: AgentCommandSurface,
        aliases: [String] = [],
        availability: AgentCommandAvailability = .available
    ) -> AgentCommandDescriptor {
        AgentCommandDescriptor(
            id: "check.\(name)",
            name: name,
            aliases: aliases,
            sourceIdentifier: "planner-check",
            surface: surface,
            availability: availability)
    }

    // Array-owned commands never reach a CLI as text, so they resolve the same
    // way on every harness — that is what makes them the cheapest tier and the
    // one with no I5 pressure at all.
    for capabilities in [
        AgentSessionCommandCapabilities.claudeOneShot,
        .oneShotProse,
        AgentSessionCommandCapabilities(interpretsLeadingSlash: false, canDelegateCommands: true),
    ] {
        expect(AgentCommandExecutionPlanner.resolve(
            descriptor("clear", surface: .array), capabilities: capabilities) == .arrayOwned,
            "B5: an Array-owned command must resolve the same way on every harness")
    }

    // The measured difference between claude and the other two.
    expect(AgentCommandExecutionPlanner.resolve(
        descriptor("compact", surface: .providerSlash),
        capabilities: .claudeOneShot) == .harnessDelegated,
        "B5: claude interprets a leading slash headlessly, so its commands stay delegated")

    let refused = AgentCommandExecutionPlanner.resolve(
        descriptor("compact", surface: .providerSlash), capabilities: .oneShotProse)
    if case let .unavailable(reason) = refused {
        expect(!reason.isEmpty, "B5: a refusal must carry a reason the user can read")
    } else {
        expect(false, "B5: codex and pi send a slash to the MODEL — the command must be disabled, not serialized into prose, got \(refused)")
    }

    // A session RPC outranks slash interpretation: pi over rpc can `compact` for
    // real even though pi one-shot cannot.
    expect(AgentCommandExecutionPlanner.resolve(
        descriptor("compact", surface: .providerSlash),
        capabilities: AgentSessionCommandCapabilities(
            interpretsLeadingSlash: false, canDelegateCommands: true)) == .harnessDelegated,
        "B5: a session RPC makes a command delegable even when the CLI ignores slashes")

    // Discovery narrows, and only once it has actually happened. claude
    // publishes `slash_commands` on `system/init`, which arrives PER TURN — so
    // before the first turn the list is nil and the baseline catalogue answers.
    // Refusing on a missing list would disable every command until a turn ran.
    var discovered = AgentSessionCommandCapabilities.claudeOneShot
    discovered.advertisedNames = ["compact", "context", "some-plugin:review"]
    expect(AgentCommandExecutionPlanner.resolve(
        descriptor("compact", surface: .providerSlash), capabilities: discovered) == .harnessDelegated,
        "B5: an advertised command stays delegated")
    expect(AgentCommandExecutionPlanner.resolve(
        descriptor("/context", surface: .providerSlash), capabilities: discovered) == .harnessDelegated,
        "B5: a descriptor name carrying its slash must still match a bare advertised name")

    let unknown = AgentCommandExecutionPlanner.resolve(
        descriptor("definitelynotacommand", surface: .providerSlash), capabilities: discovered)
    if case .unavailable = unknown {} else {
        expect(false, "B5: a command the harness did not advertise must be disabled, got \(unknown)")
    }

    // An alias counts as the command.
    expect(AgentCommandExecutionPlanner.resolve(
        descriptor("review", surface: .providerSlash, aliases: ["some-plugin:review"]),
        capabilities: discovered) == .harnessDelegated,
        "B5: an alias the harness advertises must resolve the command")

    // TR-04 — a skill is a genuine user turn, and it is now GATED like one.
    //
    // This block used to assert `.skillTemplate` for `.oneShotProse`, i.e. that a
    // skill expands on a CLI that hands a leading slash straight to the model.
    // That was survivable only because dispatch could not resolve a discovered
    // skill at all: `AgentSupervisor.accept` looked descriptors up in
    // `allBaselines()` while the menu offered discovered resources too, so a
    // `.codex/skills/foo` row refused for the wrong reason and the hole never
    // opened. Making those rows dispatchable — which TR-04 does, because
    // offering a row that cannot dispatch is the defect — turns this exact path
    // into a literal `/foo` sent to a codex or pi model for a real paid turn.
    for surface in [AgentCommandSurface.skill, .promptTemplate] {
        expect(AgentCommandExecutionPlanner.resolve(
            descriptor("plan", surface: surface), capabilities: .claudeOneShot) == .skillTemplate,
            "B5: a \(surface.rawValue) expands into a prompt on a CLI that reads a leading slash")
        let refusedSkill = AgentCommandExecutionPlanner.resolve(
            descriptor("plan", surface: surface), capabilities: .oneShotProse)
        if case .unavailable = refusedSkill {} else {
            expect(false, "TR-04: a \(surface.rawValue) on a CLI that sends a slash to the MODEL must be disabled, got \(refusedSkill)")
        }
        // Discovery narrows a skill exactly as it narrows a provider slash: a
        // custom command claude has not published is a command claude will
        // answer "Unknown command" to.
        expect(AgentCommandExecutionPlanner.resolve(
            descriptor("definitelynotaskill", surface: surface), capabilities: discovered)
            == .unavailable(reason: "This agent doesn't have that command."),
            "TR-04: an unadvertised \(surface.rawValue) must be disabled, not expanded")
    }

    // TR-04 — `.requiresTrust` is a refusal, not a fall-through.
    //
    // An untrusted `.ts`/`.js` extension is disabled in the picker
    // (`isEnabled` is false for every non-`.available` case), so nothing could
    // reach it by clicking — but the classifier is also the answer for a
    // persisted invocation, and it said "delegate this" for a resource whose
    // entire availability story is "do not load this until the user trusts it".
    let untrusted = AgentCommandExecutionPlanner.resolve(
        descriptor("ext", surface: .extensionCommand,
                   availability: .requiresTrust("Trust this extension before loading executable code")),
        capabilities: .claudeOneShot)
    expect(untrusted == .unavailable(reason: "Trust this extension before loading executable code"),
           "TR-04: a requiresTrust descriptor must refuse and keep its own reason, got \(untrusted)")

    let unknownAvailability = AgentCommandExecutionPlanner.resolve(
        descriptor("mystery", surface: .providerSlash, availability: .unknown),
        capabilities: .claudeOneShot)
    if case .unavailable = unknownAvailability {} else {
        expect(false, "TR-04: an unknown availability must refuse, got \(unknownAvailability)")
    }

    // A shell command stays refused, which is the one thing today's code got
    // right, and it keeps its own words.
    if case .unavailable = AgentCommandExecutionPlanner.resolve(
        descriptor("git", surface: .cli), capabilities: .claudeOneShot) {} else {
        expect(false, "B5: a CLI-surface command must stay refused")
    }

    // A descriptor that already declared itself unavailable keeps ITS reason,
    // rather than being overwritten by a generic one.
    let declared = AgentCommandExecutionPlanner.resolve(
        descriptor("agent", surface: .providerSlash, availability: .unavailable("advertised with nothing behind it")),
        capabilities: .claudeOneShot)
    expect(declared == .unavailable(reason: "advertised with nothing behind it"),
           "B5: a declared unavailability must keep its own reason, got \(declared)")

    print("Agent command execution planner checks passed: Array-owned on every harness, claude delegated, codex/pi disabled with a reason instead of serialized into prose, session RPC outranking slash interpretation, discovery narrowing only once it has happened, skills gated by the same transport fact as slashes, and requiresTrust/unknown refusing instead of falling through")
}
