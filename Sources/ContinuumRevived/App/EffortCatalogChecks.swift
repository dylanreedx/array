import AppKit
import ContinuumRevivedCore

@MainActor
func runEffortCatalogChecks() throws {
    struct Failure: Error { let message: String }
    func expect(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    defer { AgentModelCatalog.shared.resetForQA() }
    for harness in [AgentHarness.claudeCode, .codex] {
        let fixture = harness == .claudeCode ? AgentCatalogQAFixture.claude : AgentCatalogQAFixture.codex
        let model = fixture.models[0]
        func install(_ efforts: [String: [String]]) {
            AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: harness, readiness: .ready,
                models: fixture.models, effortLevels: efforts, defaultModel: model))
        }
        install([model: ["future-effort"]])
        let suite = "effort-catalog-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("preserved-legacy", forKey: AgentModelConfig.thinkingKey)
        try expect(AgentModelConfig.launchSelection(harness: harness, model: model, thinking: "future-effort", defaults: defaults)?.thinking == "future-effort", "explicit catalogue effort must be accepted")
        try expect(AgentModelConfig.launchSelection(harness: harness, model: model, thinking: "high", defaults: defaults) == nil, "unlisted explicit request must be refused")
        try expect(AgentModelConfig.launchSelection(harness: harness, model: model, defaults: defaults)?.thinking == "preserved-legacy", "inherited persisted effort must remain intact")
        var record = AgentRecord(id: AgentID(rawValue: UUID()), displayName: "Effort check", harness: harness,
                                 model: model, thinking: "future-effort", cwd: "/tmp",
                                 createdAt: Date(), lastActivityAt: Date())
        let footer = AgentComposerFooterView(frame: .zero)
        footer.apply(AgentLaunchSelection(harness: harness, model: model, thinking: "future-effort"))
        try expect(footer.qaEffortTitles == ["Future-Effort"], "picker must offer exactly the selected model's live efforts: \(footer.qaEffortTitles)")
        func launch() throws {
            for mode in [AgentMode.free, .managed] {
                record.mode = mode
                for resumed in [false, true] {
                    record.providerSessionId = resumed ? UUID().uuidString : nil
                    record.codexThreadId = resumed ? "fixture-thread" : nil
                    if harness == .claudeCode {
                        for fork in [false, true] {
                            record.pendingSessionForkFrom = fork ? UUID().uuidString : nil
                            let c = AgentSupervisor.claudeRunnerConfig(for: record)
                            let args = ClaudeAgentRunner.processArguments(model: c.model, effort: c.effort,
                                sessionMode: c.forkSession ? .fork : (c.conversationMayExist ? .resume : .start),
                                sessionId: c.sessionId, extraArgs: c.extraArgs, workspaceMCP: c.workspaceMCP, mode: c.mode)
                            try expect(c.effort == "future-effort" && args.contains("future-effort"), "unknown advertised effort must reach Claude runner on every launch")
                        }
                    } else {
                        let c = AgentSupervisor.codexRunnerConfig(for: record)
                        let args = CodexCLIBackend.processArguments(model: c.model, effort: c.effort,
                            sessionMode: resumed ? .resume : .fresh, threadId: c.threadId, cwdPath: c.cwd.path,
                            extraArgs: c.extraArgs, prompt: AgentPrompt(text: "fixture"), workspaceMCP: c.workspaceMCP)
                        try expect(c.effort == "future-effort" && args.contains("model_reasoning_effort=future-effort"), "advertised effort must reach Codex runner")
                    }
                }
            }
        }
        try launch()
        for metadata in [[model: ["low"]], [:], [model: []]] {
            install(metadata)
            record.thinking = "high"
            footer.apply(AgentLaunchSelection(harness: harness, model: model, thinking: record.thinking))
            try expect(!footer.qaEffortTitles.contains("High"), "stale stored effort must not become an offered capability")
            for mode in [AgentMode.free, .managed] {
                record.mode = mode
                let effort = harness == .claudeCode ? AgentSupervisor.claudeRunnerConfig(for: record).effort : AgentSupervisor.codexRunnerConfig(for: record).effort
                try expect(effort == nil && record.thinking == "high", "unknown/stale metadata must omit flag and preserve stored effort")
            }
        }
    }
    let piModel = AgentCatalogQAFixture.pi[0]
    for args in [
        PiAgentRunner.processArguments(model: piModel, thinking: "high", sessionId: nil, extraArgs: [], prompt: "fixture"),
        PiRpcAgentRunner.processArguments(model: piModel, thinking: "high", sessionId: "resume", extraArgs: [])
    ] {
        try expect(!args.contains("--thinking") && args.contains(piModel), "Pi without capability metadata must use its own effort default and preserve model")
    }
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("effort-tile-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: support) }
    let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: support), makeRunner: { _ in ScriptedAgentRunner(script: []) })
    let tileID = UUID()
    let agent = supervisor.spawn(role: nil, prompt: nil, cwd: support, harness: .claudeCode,
        model: AgentCatalogQAFixture.claude.models[0], thinking: "preserved-legacy", tileId: tileID)
    let tile = ManagedAgentTileNSView(tile: Tile(id: tileID, kind: .managedAgent, title: "effort",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 360), zPosition: .fromLegacyRank(1),
        runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
    tile.attach(agentID: agent, supervisor: supervisor)
    try expect(tile.qaPickHarness(.pi), "a harness change must preserve inherited stale effort rather than reject it")
    try expect(supervisor.records[agent]?.thinking == "preserved-legacy", "harness switch must not invent a replacement effort")
    print("Effort catalogue checks passed")
}
