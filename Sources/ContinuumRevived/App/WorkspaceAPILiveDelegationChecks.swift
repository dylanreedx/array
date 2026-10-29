import AppKit
import ContinuumRevivedCore
import Foundation

/// Paid, opt-in acceptance. No catalogue fixtures or scripted runners.
@MainActor
func runWorkspaceAPILiveDelegationChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    let environment = ProcessInfo.processInfo.environment
    guard environment["ARRAY_DELEGATION_LIVE"] == "1",
          environment["CONTINUUM_APP_SUPPORT"] != nil,
          let evidencePath = environment["ARRAY_DELEGATION_LIVE_EVIDENCE"],
          Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
        throw Failure(description: "Live delegation requires ARRAY_DELEGATION_LIVE=1, isolated app support and an evidence path (dev only).")
    }
    var evidence: [[String: Any]] = []
    func save() throws {
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: evidencePath), options: .atomic)
    }
    try save()
    let catalog = AgentModelCatalog.shared
    catalog.enableLiveRefresh()
    guard await waitUntil(timeout: 30, pollInterval: 0.1, { !catalog.refreshInFlightForQA }) else {
        throw Failure(description: "Live catalogue probe timed out")
    }
    func select(_ harness: AgentHarness) throws -> String {
        let snapshot = catalog.snapshot(for: harness)
        guard snapshot.readiness.canRun else { throw Failure(description: "\(harness.rawValue): \(snapshot.readiness)") }
        let key = harness == .claudeCode ? "ARRAY_DELEGATION_LIVE_CLAUDE_MODEL" : harness == .codex ? "ARRAY_DELEGATION_LIVE_CODEX_MODEL" : "ARRAY_DELEGATION_LIVE_PI_MODEL"
        let preferred = snapshot.models.first { harness == .claudeCode ? $0.localizedCaseInsensitiveContains("haiku") : $0.localizedCaseInsensitiveContains("mini") }
            ?? snapshot.models.first { $0.localizedCaseInsensitiveContains("luna") } ?? snapshot.seedModel
        guard let model = environment[key] ?? preferred, model.contains("/"), snapshot.models.contains(model) else {
            throw Failure(description: "\(harness.rawValue): choose an exact id from its live catalogue via \(key)")
        }
        print("LIVE catalogue selection: \(harness.rawValue) \(model)")
        return model
    }
    let claudeModel = try select(.claudeCode)
    let codexModel = try select(.codex)
    var directions: [(AgentHarness, String, AgentHarness, String)] = [(.claudeCode, claudeModel, .codex, codexModel), (.codex, codexModel, .claudeCode, claudeModel)]
    if environment["ARRAY_DELEGATION_LIVE_PI"] == "1" { directions.append((.claudeCode, claudeModel, .pi, try select(.pi))) }
    for (source, sourceModel, target, targetModel) in directions {
        let fixture = try WorkspaceInvariantsFixture(label: "live-delegation")
        defer { fixture.dispose() }
        let root = fixture.projectRoots[WorkspaceInvariantsFixture.projectA1]!
        var supervisor: AgentSupervisor!
        fixture.configureMount = { delegate, _ in
            supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: fixture.appSupport),
                nameTitlerCommand: { _ in nil }, claudeSessionTitle: { _, _ in nil },
                submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: fixture.appSupport),
                transcriptStore: AgentTranscriptStore(root: fixture.appSupport.appendingPathComponent("transcripts")))
            supervisor.workspaceToolsPermission = { .free }
            delegate.agentSupervisor = supervisor
        }
        try fixture.mount()
        defer { supervisor.stopAll() }
        let parent = supervisor.spawn(role: nil, prompt: nil, cwd: root, harness: source, model: sourceModel,
            thinking: "low", projectId: WorkspaceInvariantsFixture.projectA1, projectRoot: root, displayName: "Live delegation parent")
        _ = supervisor.setWorkspaceToolsEnabled(agentID: parent, true)
        var text: [AgentID: String] = [:]
        var answers: [AgentID: [String]] = [:]
        var tools: [AgentID: [String]] = [:]
        var chips: [(AgentID, String, String?)] = []
        var failures: [String] = []
        let observer = supervisor.addDeliveredEventObserver { id, event in
            switch event {
            case .turnStarted: text[id] = ""
            case let .contentDelta(_, _, .assistant, delta): text[id, default: ""] += delta
            case let .itemStarted(_, _, _, title):
                tools[id, default: []].append(title ?? "")
            case let .childAgentSpawned(_, child, _, _, item, provider, _) where id == parent:
                chips.append((AgentID(rawValue: child), provider, item))
            case let .turnCompleted(_, _, outcome, error):
                answers[id, default: []].append(text[id] ?? "")
                if outcome == .failed { failures.append("\(id.rawValue): \(error ?? "turn failed")") }
            case let .runtimeError(_, message): failures.append(message)
            default: break
            }
        }
        defer { supervisor.removeDeliveredEventObserver(observer) }
        let index = evidence.count
        evidence.append(["parentHarness": source.rawValue, "parentModel": sourceModel, "childHarness": target.rawValue, "childModel": targetModel, "status": "running"])
        try save()
        let prompt = """
        Live Array acceptance test. Use only Array workspace MCP tools (load with ToolSearch if deferred). Do not use shell or built-in Agent/Task/spawn_agent.
        1. Call array_delegate exactly once: harness "\(target.rawValue)", model "\(targetModel)", task "Reply only KIWI. Do not use tools.", title "Live KIWI child", idempotencyKey "live-kiwi", presentation {"camera":"preserve"}.
        2. Call wait_agents with the returned operationId handle and timeoutSeconds 120. Read the child's answer.
        3. Call array_message_agent with that childAgentId, text "Reply only PLUM. Do not use tools.", idempotencyKey "live-plum", presentation {"camera":"preserve"}.
        4. Call wait_agents again with the same delegation operationId and timeoutSeconds 120. Read the child's new answer.
        5. Your final answer must be exactly KIWI PLUM, but only if both actual wait results contain those answers. If any call fails, report its exact error and stop. Do not invent answers or retry by another route.
        """
        print("LIVE starting \(source.rawValue) → \(target.rawValue)")
        guard supervisor.send(prompt, to: parent) else { throw Failure(description: "Parent send refused") }
        let completed = await waitUntil(timeout: 300, pollInterval: 0.1) {
            !supervisor.isRunning(parent) && !(answers[parent] ?? []).isEmpty
        }
        let children = supervisor.children(of: parent)
        let child = children.first
        let record = child.flatMap { supervisor.records[$0] }
        let parentAnswers = answers[parent] ?? []
        let childAnswers = child.flatMap { answers[$0] } ?? []
        let calls = tools[parent] ?? []
        evidence[index]["parentAnswers"] = parentAnswers
        evidence[index]["childAnswers"] = childAnswers
        evidence[index]["parentToolCalls"] = calls
        evidence[index]["failures"] = failures
        evidence[index]["childRecordHarness"] = record?.harness?.rawValue
        evidence[index]["childRecordModel"] = record?.model
        evidence[index]["chipProviders"] = chips.map { $0.1 }
        evidence[index]["chipSourceIds"] = chips.compactMap { $0.2 }
        let finalLine = supervisor.latestAssistantLine(for: parent)
        evidence[index]["parentFinalLine"] = finalLine
        let passed = completed && children.count == 1 && record?.harness == target && record?.model == targetModel
            && record?.parentAgentID == parent && chips.contains { $0.0 == child && $0.1 == target.rawValue && $0.2 != nil }
            && childAnswers.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "KIWI" }
            && childAnswers.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "PLUM" }
            && finalLine == "KIWI PLUM"
            && calls.contains { $0.contains("array_delegate") } && calls.filter { $0.contains("wait_agents") }.count >= 2
            && calls.contains { $0.contains("array_message_agent") }
        evidence[index]["status"] = passed ? "passed" : "failed"
        try save()
        print("LIVE \(source.rawValue) → \(target.rawValue): child=\(childAnswers) parent=\(parentAnswers) tools=\(calls)")
        guard passed else { throw Failure(description: "Live \(source.rawValue) → \(target.rawValue) failed; inspect \(evidencePath)") }
        supervisor.stopAll()
    }
    print("Live cross-harness delegation passed: \(evidence.count) directions")
}
