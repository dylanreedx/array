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
    if let path = ProcessInfo.processInfo.environment["CONTINUUM_EFFORT_RENDER_DIR"], !path.isEmpty {
        try captureEffortCatalogQA(to: URL(fileURLWithPath: path, isDirectory: true))
    }
    print("Effort catalogue checks passed")
}

/// Opt-in artifact QA only. Uses the production footer and its Choice items;
/// annotations explain the fixture and are deliberately outside product chrome.
@MainActor
private func captureEffortCatalogQA(to directory: URL) throws {
    struct Failure: Error { let message: String }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var manifest: [[String: Any]] = []
    for harness in [AgentHarness.claudeCode, .codex] {
        let fixture = harness == .claudeCode ? AgentCatalogQAFixture.claude : AgentCatalogQAFixture.codex
        let model = harness == .claudeCode ? fixture.models[1] : fixture.models[0]
        let harnessName = harness == .claudeCode ? "claude" : "codex"
        for advertised in [true, false] {
            let state = advertised ? "advertised" : "missing-metadata"
            let stored = advertised ? "future-effort" : "high"
            AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: harness, readiness: .ready,
                models: fixture.models, displayNames: fixture.displayNames,
                effortLevels: advertised ? [model: ["future-effort"]] : [:], defaultModel: model))
            var digests: [String] = []
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let size = NSSize(width: 720, height: 220)
                var footer: AgentComposerFooterView!
                let probe = try UIProbe.render(.init(id: "effort.\(harnessName).\(state).\(name)", size: size, appearance: appearance)) {
                    let body = NSView(frame: NSRect(origin: .zero, size: size))
                    body.wantsLayer = true
                    body.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
                    func annotation(_ text: String, y: CGFloat) {
                        let label = NSTextField(labelWithString: text)
                        label.font = .systemFont(ofSize: 12)
                        label.textColor = .secondaryLabelColor
                        label.frame = NSRect(x: 20, y: y, width: 680, height: 20)
                        body.addSubview(label)
                    }
                    annotation(advertised
                        ? "QA fixture: selected model advertises future-effort"
                        : "QA fixture: no effort metadata; runner omits effort flag (CLI default)", y: 180)
                    footer = AgentComposerFooterView(frame: NSRect(x: 20, y: 132, width: 680, height: AgentComposerFooterView.height))
                    footer.apply(.init(harness: harness, model: model, thinking: stored))
                    body.addSubview(footer)
                    footer.applyTokens()
                    footer.layoutSubtreeIfNeeded()
                    if advertised {
                        let choices = ChoiceListView(items: footer.effortButton.items, selectedID: footer.effortButton.selectedID)
                        let anchor = footer.effortButton.convert(footer.effortButton.bounds, to: body)
                        let listSize = choices.intrinsicContentSize
                        choices.frame = NSRect(x: min(anchor.minX, size.width - listSize.width - 20),
                                               y: footer.frame.minY - listSize.height - 8,
                                               width: listSize.width, height: listSize.height)
                        body.addSubview(choices)
                    } else {
                        annotation("QA annotation: stored effort is High; no effort choices are offered.", y: 86)
                    }
                    return body
                }
                guard footer.effortButton.qaTitleDrawsWithoutTruncation,
                      let data = probe.hostRep.representation(using: .png, properties: [:]) else {
                    throw Failure(message: "effort artifact truncated or unavailable")
                }
                let filename = "\(harnessName)-\(state)-\(name).png"
                try data.write(to: directory.appendingPathComponent(filename))
                digests.append(probe.contentDigest)
                manifest.append(["file": filename, "appearance": appearance.rawValue,
                    "harness": harness.rawValue, "model": model, "storedEffort": stored,
                    "offeredEfforts": footer.effortButton.items.map(\.id),
                    "renderedEffortCaption": footer.effortButton.qaRenderedTitle,
                    "launchEffort": AgentModelConfig.supportedEffort(stored, model: model, harness: harness) as Any? ?? NSNull(),
                    "contentDigest": probe.contentDigest, "scale": UIProbe.renderScale])
                probe.window.orderOut(nil)
            }
            guard digests.count == 2 && digests[0] != digests[1] else {
                throw Failure(message: "light and dark effort renders must differ")
            }
        }
    }
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("manifest.json"))
    print("Effort artifact QA: 8 PNGs and manifest at \(directory.path)")
}
