import ContinuumRevivedCore
import Foundation

@MainActor
func runStrictAgentHarnessChecks() throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    func record(_ harness: AgentHarness, model: String) -> AgentRecord {
        AgentRecord(
            id: AgentID(rawValue: UUID()),
            displayName: "Harness check",
            harness: harness,
            model: model,
            thinking: "high",
            cwd: "/private/tmp",
            createdAt: Date(),
            lastActivityAt: Date())
    }

    let claude = AgentSupervisor.productionRunner(for: record(.claudeCode, model: "anthropic/opus"))
    let codex = AgentSupervisor.productionRunner(for: record(.codex, model: "openai-codex/gpt-5.6-sol"))
    let piRecord = record(.pi, model: "openai-codex/gpt-5.6-sol")
    let pi = AgentSupervisor.productionRunner(for: piRecord)
    try expect(claude is ClaudeAgentRunner, "Claude Code did not construct ClaudeAgentRunner")
    try expect(codex is CodexAgentRunner, "Codex did not construct CodexAgentRunner")
    try expect(pi is PiAgentRunner, "Pi + OpenAI model did not construct PiAgentRunner")
    let piConfig = AgentSupervisor.runnerConfig(for: piRecord)
    let piArgs = PiAgentRunner.processArguments(model: piConfig.model, thinking: piConfig.thinking, sessionId: piConfig.sessionId, extraArgs: piConfig.extraArgs, prompt: "PROMPT")
    try expect(piArgs == ["-p", "--mode", "json", "--model", "openai-codex/gpt-5.6-sol", "--thinking", "high", "--session-id", AgentSupervisor.sessionId(for: piRecord.id), "PROMPT"],
               "strict Pi argv changed: \(piArgs)")

    // C8: pi subagent spawning had four independent blockers; this is #3 —
    // whenever `PiAgentRunner.Config.extensionPaths` carries a path (its own
    // default resolves it from the real ~/.pi/agent/extensions at spawn
    // time — impure by design, so NOT re-asserted here against host state),
    // `run()` must forward it into pi's argv as `-e <path>`, or
    // continuum-spawn-agent.ts never loads no matter what the role allowlist
    // permits. This pins the pure plumbing with a fixture path; the impure
    // resolution (does the file actually exist on disk?) is covered
    // separately by PiExtensionInstallerChecks against an injected throwaway
    // root — never the real ~/.pi here.
    let fixtureExtensionPath = "/private/tmp/continuum-c8-fixture/continuum-spawn-agent.ts"
    let piArgsWithExtension = PiAgentRunner.processArguments(
        model: piConfig.model, thinking: piConfig.thinking, sessionId: piConfig.sessionId,
        extraArgs: piConfig.extraArgs, prompt: "PROMPT", extensionPaths: [fixtureExtensionPath])
    try expect(piArgsWithExtension == ["-p", "--mode", "json", "--model", "openai-codex/gpt-5.6-sol", "--thinking", "high",
                                       "--session-id", AgentSupervisor.sessionId(for: piRecord.id),
                                       "-e", fixtureExtensionPath, "PROMPT"],
               "strict Pi argv's -e must sit right after the session flag, ahead of extras and the prompt, got \(piArgsWithExtension)")

    let catalog = AgentModelCatalog()
    catalog.resetForQA(snapshot: .init(harness: .claudeCode, readiness: .ready, models: ["anthropic/opus"], displayNames: ["anthropic/opus": "Claude"], contextWindows: ["anthropic/opus": 1]))
    catalog.resetForQA(snapshot: .init(harness: .codex, readiness: .loggedOut, models: ["openai-codex/gpt-5.6-sol"], displayNames: ["openai-codex/gpt-5.6-sol": "Codex"], contextWindows: ["openai-codex/gpt-5.6-sol": 2]))
    catalog.resetForQA(snapshot: .init(harness: .pi, readiness: .ready, models: ["google/gemini"], displayNames: ["google/gemini": "Gemini"], contextWindows: ["google/gemini": 3]))
    try expect(catalog.snapshot(for: .claudeCode).models == ["anthropic/opus"], "Claude catalogue leaked")
    try expect(catalog.snapshot(for: .codex).readiness == .loggedOut, "Codex readiness leaked")
    try expect(catalog.snapshot(for: .pi).displayNames == ["google/gemini": "Gemini"], "Pi metadata leaked")

    try expect(LegacyAgentHarnessMigration.resolve(
        evidence: .init(hasCodexThread: false, hasClaudeConversation: true, hasPiSession: true),
        storedPreference: .claudeCode) == nil, "ambiguous Claude/Pi evidence guessed")

    // Every state that refuses a prompt must SAY why. All three are reachable in
    // ordinary use — a legacy record whose harness could not be inferred, the
    // seconds after launch while the catalogue probe is still out, and a model that
    // is not the harness's. Each was silent before: `send` returned false, the
    // caller returned, and the prompt simply did not go.
    let refusalCatalog = AgentModelCatalog()
    refusalCatalog.resetForQA(snapshot: .init(harness: .claudeCode, readiness: .ready, models: ["anthropic/opus"]))
    refusalCatalog.resetForQA(snapshot: .init(harness: .codex, readiness: .checking, models: ["openai-codex/gpt-5.6-sol"]))
    refusalCatalog.resetForQA(snapshot: .init(harness: .pi, readiness: .loggedOut, models: ["google/gemini"]))

    var unresolved = record(.claudeCode, model: "anthropic/opus")
    unresolved.harness = nil
    func refusal(_ probe: AgentRecord) -> String {
        AgentSupervisor.sendRefusal(record: probe, catalog: refusalCatalog) ?? "<accepted>"
    }
    try expect(refusal(unresolved).contains("harness ownership is unresolved"),
               "an unresolved harness refused without saying so: \(refusal(unresolved))")
    try expect(refusal(record(.codex, model: "openai-codex/gpt-5.6-sol")).contains("still starting up"),
               "a still-probing harness refused without saying so: \(refusal(record(.codex, model: "openai-codex/gpt-5.6-sol")))")
    try expect(refusal(record(.pi, model: "google/gemini")).contains("logged out"),
               "a logged-out harness refused without saying so: \(refusal(record(.pi, model: "google/gemini")))")
    try expect(refusal(record(.claudeCode, model: "openai-codex/gpt-5.6-sol")).contains("cannot run"),
               "a model the harness does not own refused without saying so: \(refusal(record(.claudeCode, model: "openai-codex/gpt-5.6-sol")))")
    try expect(AgentSupervisor.sendRefusal(record: record(.claudeCode, model: "anthropic/opus"), catalog: refusalCatalog) == nil,
               "a ready harness holding its own model was refused")

    let countable = AgentModelCatalog(probeExecutor: { _, arguments, _ in
        switch arguments {
        case ["--list-models"]: return "provider model context max-out thinking images\nopenai-codex gpt-test 1 1 yes no"
        case ["auth", "status", "--json"]: return #"{"loggedIn":true}"#
        case ["login", "status"]: return "Logged in using ChatGPT"
        default: return nil
        }
    })
    countable.enableLiveRefresh()
    try expect(!countable.requestRefresh(), "an in-flight catalogue refresh was not coalesced")
    for _ in 0..<100 where countable.refreshInFlightForQA { Thread.sleep(forTimeInterval: 0.01) }
    let completedProbeCount = countable.probeLaunchCountForQA
    try expect(completedProbeCount == 3, "one refresh did not run exactly three harness probes: \(completedProbeCount)")
    try expect(!countable.requestRefresh(now: Date()), "the 15-second refresh throttle was bypassed")
    _ = countable.snapshot(for: .claudeCode)
    _ = countable.snapshot(for: .codex)
    _ = countable.snapshot(for: .pi)
    try expect(countable.probeLaunchCountForQA == completedProbeCount, "snapshot rendering spawned a probe")
}
