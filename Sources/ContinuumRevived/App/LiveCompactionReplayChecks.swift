import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// `--live-compaction-replay-check`: the opt-in live compaction leg's seed turn,
/// replayed offline. Same supervisor (transcript store, submission recovery),
/// same `spawn`, same window-hosted attached tile and the same completion predicate
/// as `runAgentContextLiveCompactionChecks`'s `complete(_:label:expectedReply:)`;
/// the only difference is a scripted runner in place of the installed CLI. It
/// separates "the provider never finished the turn" from "Array never showed the
/// finished turn", without spending anyone's usage.
@MainActor
enum LiveCompactionReplayChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("live-compaction-replay-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let harnesses: [(AgentHarness, String, Int)] = [
            (.claudeCode, AgentCatalogQAFixture.claude.models[0], 1_000_000), (.codex, AgentCatalogQAFixture.codex.models[0], 258_400), (.pi, AgentCatalogQAFixture.pi[0], 258_400),
        ]
        for (harness, model, window) in harnesses {
            try await seedTurn(harness: harness, model: model, window: window,
                               scratch: root.appendingPathComponent(harness.rawValue, isDirectory: true))
        }
        print("PASS: the live compaction seed turn finishes, renders SEED_OK and is retained on every harness when the provider answers")
    }

    private static func seedTurn(harness: AgentHarness, model: String, window: Int, scratch: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let thread = "provider"
        let script: [AgentRuntimeEvent] = [
            .turnStarted(threadId: thread, turnId: "seed"),
            .contextWindowUpdated(threadId: thread, snapshot: AgentContextWindowSnapshot(
                usedTokens: 2_952, maxTokens: window, observedAt: Date(), source: .providerSessionStats, freshness: .live)),
            .contentDelta(threadId: thread, turnId: "seed", streamKind: .assistant, delta: "SEED_OK"),
            .turnCompleted(threadId: thread, turnId: "seed", outcome: .completed, errorMessage: nil),
        ]
        let drafts = AgentComposerDraftStore(
            applicationSupportDirectory: scratch.appendingPathComponent("drafts-store", isDirectory: true), debounceInterval: 0)
        let transcriptStore = AgentTranscriptStore(root: scratch.appendingPathComponent("transcripts", isDirectory: true))
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: scratch.appendingPathComponent("records", isDirectory: true)),
            makeRunner: { _ in ScriptedAgentRunner(script: script) },
            warn: { _ in }, nameTitlerCommand: { _ in nil }, nameGenerationTimeout: 1,
            claudeSessionTitle: { _, _ in nil }, submissionRecoveryStore: drafts, transcriptStore: transcriptStore)
        let project = scratch.appendingPathComponent("empty-checkout", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let tileID = UUID()
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: project, harness: harness, model: model, thinking: "none", tileId: tileID)
        let fixture = AgentContextCompactionTileFixture.makeAttachedTile(
            supervisor: supervisor, id: id, tileID: tileID, scratch: scratch)
        let tile = fixture.tile
        defer { tile.detach(); supervisor.stop(id); fixture.window.orderOut(nil) }

        // `complete(_:label:expectedReply:)`'s predicate, with a 10 s deadline in
        // place of the provider's 600 s.
        let priorCardCount = tile.qaRenderedCardCount
        guard supervisor.send(AgentPrompt("Remember this exact marker. Reply only SEED_OK. Do not use tools."), to: id) else {
            throw Failure(description: "\(harness.rawValue): the seed send was refused")
        }
        let deadline = Date().addingTimeInterval(10)
        var finished = false
        while Date() < deadline {
            tile.layoutSubtreeIfNeeded()
            if !supervisor.isRunning(id) && tile.qaRenderedCardCount > priorCardCount
                && tile.qaLastAssistantCardBody?.trimmingCharacters(in: .whitespacesAndNewlines) == "SEED_OK" { finished = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard finished else {
            throw Failure(description: "\(harness.rawValue): the seed turn did not finish and render (running=\(supervisor.isRunning(id)) cards \(priorCardCount)->\(tile.qaRenderedCardCount) body=\(String(describing: tile.qaLastAssistantCardBody)))")
        }
        guard let used = supervisor.contextWindowSnapshot(for: id)?.usedTokens, used > 0 else {
            throw Failure(description: "\(harness.rawValue): no prompt-token reading after the seed")
        }
        // The live leg's retention read: the durable transcript holds the reply.
        var retained = false
        for _ in 0..<100 {
            if let document = try await transcriptStore.load(agentID: id, sessionID: AgentTranscriptStore.canonicalSessionID(for: id)),
               String(decoding: try SharedAgentTranscriptWire.encode(AgentDocument(entries: document.entries.filter { $0.role == .assistant })), as: UTF8.self).contains("SEED_OK") { retained = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard retained else { throw Failure(description: "\(harness.rawValue): the saved transcript does not hold the seed reply") }
        print("METRIC live-compaction-replay harness=\(harness.rawValue) seed=finished-rendered-retained usedTokens=\(used)")
    }
}
