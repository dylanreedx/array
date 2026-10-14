import Foundation
import ContinuumRevivedCore

func runAgentContextMeterContractChecks() {
    runAgentContextOccupancyChecks()
    runClaudeContextOccupancyChecks()
    let claudeProbeArgs = ClaudeCLIBackend.modelProbeArguments
    func claudeProbeValue(after option: String) -> String? {
        guard let index = claudeProbeArgs.firstIndex(of: option), claudeProbeArgs.indices.contains(index + 1) else { return nil }
        return claudeProbeArgs[index + 1]
    }
    expect(claudeProbeValue(after: "--tools") == ""
           && claudeProbeArgs.contains("--strict-mcp-config")
           && claudeProbeValue(after: "--setting-sources") == "",
           "Claude's model-only initialize probe must disable tools, MCP, user settings, and setting sources")
    expect(AgentModelCatalog.piModelProbeArguments == [
        "--list-models", "--no-tools", "--no-extensions", "--no-skills", "--no-context-files",
    ], "Pi's model-only catalogue probe must disable tools, extensions, skills, and context files")
    let suite = "array.context-policy-check.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    expect(AgentContextAutoCompactionPolicy.threshold(defaults: defaults) == 0.90,
           "all providers default to the same 90 percent auto-compaction threshold")
    defaults.set(80, forKey: AgentContextAutoCompactionPolicy.percentKey)
    expect(AgentContextAutoCompactionPolicy.threshold(defaults: defaults) == 0.80,
           "user percentage must control all providers")
    defaults.set(false, forKey: AgentContextAutoCompactionPolicy.enabledKey)
    expect(AgentContextAutoCompactionPolicy.threshold(defaults: defaults) == nil,
           "auto-compaction must honor the user's disabled setting")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-context-contract-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = "provider/model-exact"
    let resolver = AgentContextWindowResolver(applicationSupportDirectory: root, bundledWindows: [model: 300])
    expect(resolver.resolve(harness: .claudeCode, model: model, stated: 500, piStore: 900).source == .provider,
           "provider window must win the ladder")
    let another = AgentContextWindowResolver(applicationSupportDirectory: root, bundledWindows: [model: 300])
    expect(another.resolve(harness: .claudeCode, model: model).tokens == 500,
           "provider window must be remembered across agents and relaunch")
    expect(another.resolve(harness: .codex, model: model, piStore: 900).tokens == 300,
           "remembered values must be harness scoped; bundled window precedes pi")
    let empty = AgentContextWindowResolver(bundledWindows: [:])
    expect(empty.resolve(harness: .claudeCode, model: model, piStore: 900).source == .unknown,
           "Claude must never borrow pi's store")
    expect(empty.resolve(harness: .codex, model: model, piStore: 900).source == .unknown,
           "Codex must never borrow pi's store")
    expect(empty.resolve(harness: .pi, model: model, piStore: 900).source == .piStore,
           "pi may use its own store after the bundled ladder")
    expect(empty.resolve(harness: .pi, model: model, stated: 0, piStore: -1).tokens == nil,
           "invalid windows must remain unknown")
    expect(empty.shouldReportUnknown(harness: .pi, model: model), "first unknown must report")
    expect(!empty.shouldReportUnknown(harness: .pi, model: model), "unknown notices must not repeat")
    expect(resolver.shouldReportUnknown(harness: .claudeCode, model: "provider/unknown"),
           "startup resolver must report the first app-scoped unknown")
    expect(!another.shouldReportUnknown(harness: .claudeCode, model: "provider/unknown"),
           "startup and telemetry resolvers must share one app-lifetime unknown notice")
    let differentApp = AgentContextWindowResolver(applicationSupportDirectory: root.appendingPathComponent("other-app"), bundledWindows: [:])
    expect(differentApp.shouldReportUnknown(harness: .claudeCode, model: "provider/unknown"),
           "unknown-report latch must remain isolated by application support directory")
    let catalog = AgentModelCatalog()
    let bundled = AgentContextWindowResolver()
    expect(!AgentContextWindowResolver.bundledWindows().isEmpty, "ContextWindows.json must ship with the checks/app resource bundle")
    let offered = [AgentHarness.claudeCode, .codex, .pi].map { catalog.snapshot(for: $0) }
    expect(offered.allSatisfy { !$0.models.isEmpty }, "offered-model invariant must run on nonempty CLI fixture catalogues")
    let unresolved = bundled.unresolvedModels(in: offered)
    expect(unresolved.isEmpty, "every offered model must resolve a window: \(unresolved.joined(separator: ", "))")
    let captures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/context-meter/catalogs")
    do {
        let manifestData = try Data(contentsOf: captures.appendingPathComponent("manifest.json"))
        struct CaptureShapeError: Error {}
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let sources = manifest["sources"] as? [String: [String: Any]] else { throw CaptureShapeError() }
        func file(_ cli: String, _ suffix: String) throws -> Data {
            guard let version = sources[cli]?["version"] as? String else { throw CaptureShapeError() }
            return try Data(contentsOf: captures.appendingPathComponent("\(cli)-\(version).\(suffix)"))
        }
        guard let claudeFrames = try JSONSerialization.jsonObject(with: file("claude", "json")) as? [[String: Any]] else { throw CaptureShapeError() }
        guard let claudeCatalog = claudeFrames.compactMap { frame -> AgentHarnessCatalogSnapshot? in
            guard let data = try? JSONSerialization.data(withJSONObject: frame),
                  let line = String(data: data, encoding: .utf8) else { return nil }
            return ClaudeCLIBackend.parseInitializeModels(controlResponseLine: line)
        }.first else { throw CaptureShapeError() }
        guard let codexData = try JSONSerialization.jsonObject(with: file("codex", "json")) as? [String: Any],
              let codexModels = codexData["models"] as? [[String: Any]] else { throw CaptureShapeError() }
        let codexCatalog = AgentHarnessCatalogSnapshot(harness: .codex, readiness: .ready,
            models: codexModels.compactMap { ($0["slug"] as? String).map { "openai-codex/" + $0 } })
        let piData = try file("pi", "txt")
        guard let piText = String(data: piData, encoding: .utf8) else { throw CaptureShapeError() }
        let piCatalog = AgentHarnessCatalogSnapshot(harness: .pi, readiness: .ready,
            models: AgentModelCatalog.parse(listModelsOutput: piText))
        let currentOffers = [claudeCatalog, codexCatalog, piCatalog]
        expect(currentOffers.allSatisfy { !$0.models.isEmpty }, "captured current installed catalogues must be nonempty")
        let missingCurrent = bundled.unresolvedModels(in: currentOffers)
        expect(missingCurrent.isEmpty, "captured current installed model windows: \(missingCurrent)")
    } catch { expect(false, "current installed catalogue captures must decode: \(error)") }
    let fake = AgentHarnessCatalogSnapshot(harness: .claudeCode, readiness: .ready, models: ["anthropic/unrecorded"])
    expect(bundled.unresolvedModels(in: [fake]) == ["\(AgentHarness.claudeCode.rawValue):anthropic/unrecorded"],
           "the offered-model invariant must detect unknown newly offered models")
    expect(AgentContextFullRecovery.isContextFull(provider: "claude", candidates: ["prompt is too long: 1000001 tokens > 1000000 maximum"]),
           "Claude numeric prompt-too-long wording must be recognized")
    expect(AgentContextFullRecovery.isContextFull(provider: "pi", candidates: ["Your input exceeds the context window of this model"]),
           "Pi upstream context-window wording must be recognized")
    runAgentCompactionChecks()
    print("PASS: context-meter-contract — provider/remembered/bundled/pi-only/unknown ladder, shared persistence, every offered model")
}
