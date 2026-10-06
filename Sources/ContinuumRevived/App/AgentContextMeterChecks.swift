import AppKit
import ContinuumRevivedCore
import Foundation

// T1 (`.plans/69`) — the context meter, witnessed through the path a user sees:
// provider lines → the REAL translator → the supervisor's delivery → an attached
// tile's compact row. A translator-only assertion is how every one of these
// defects stayed green: each translator was right about its own frame and the
// ring was still wrong.

/// Replays provider stream lines through a real translator from inside
/// `run(prompt:)`, the way a production runner does, and can hold mid-turn at a
/// `.pause` so a witness can read the meter between two provider frames.
private final class MeterReplayRunner: AgentRunning, @unchecked Sendable {
    enum Step {
        case line(String)
        case event(AgentRuntimeEvent)
        case pause
    }

    typealias Translate = (String) -> [AgentRuntimeEvent]
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var turns: [[Step]]
    private let makeTranslate: (@escaping @Sendable (AgentRuntimeObservation) -> Void) -> Translate
    private let freshTranslatorPerRun: Bool
    private var translate: Translate?
    private var observationHandler: (@Sendable (AgentRuntimeObservation) -> Void)?
    private var pausedStorage = false
    private var finishedRuns = 0

    init(
        turns: [[Step]],
        freshTranslatorPerRun: Bool,
        makeTranslate: @escaping (@escaping @Sendable (AgentRuntimeObservation) -> Void) -> Translate
    ) {
        self.turns = turns
        self.freshTranslatorPerRun = freshTranslatorPerRun
        self.makeTranslate = makeTranslate
    }

    var isPaused: Bool { lock.withLock { pausedStorage } }
    var finishedRunCount: Int { lock.withLock { finishedRuns } }
    func resume() { gate.signal() }

    func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        let steps: [Step] = lock.withLock { turns.isEmpty ? [] : turns.removeFirst() }
        let translate: Translate = lock.withLock {
            if freshTranslatorPerRun || self.translate == nil {
                self.translate = makeTranslate { [weak self] observation in
                    self?.lock.withLock { self?.observationHandler }?(observation)
                }
            }
            return self.translate!
        }
        for step in steps {
            switch step {
            case .line(let line):
                for event in translate(line) { onEvent(event) }
            case .event(let event):
                onEvent(event)
            case .pause:
                lock.withLock { pausedStorage = true }
                gate.wait()
                lock.withLock { pausedStorage = false }
            }
        }
        lock.withLock { finishedRuns += 1 }
    }

    func stop() { gate.signal() }
    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
    func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {
        lock.withLock { observationHandler = handler }
    }
}

private func meterFixture(_ name: String) throws -> [String] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ContinuumRevivedCoreChecks/Fixtures/\(name)", isDirectory: false)
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

@MainActor
func runAgentContextMeterChecks(root: URL) async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func expectEventually(
        _ message: @autoclosure () -> String,
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: message())
    }
    func near(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 0.000_001
    }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

    func spawnWithTile(
        _ supervisor: AgentSupervisor, harness: AgentHarness, model: String
    ) -> (AgentID, ManagedAgentTileNSView) {
        let tileID = UUID()
        let id = supervisor.spawn(
            role: nil, prompt: nil, cwd: cwd, harness: harness,
            model: model, thinking: AgentModelConfig.resolvedFromDefaults(harness: harness).thinking,
            tileId: tileID)
        return (id, attachTile(supervisor, id, tileID: tileID))
    }
    func attachTile(_ supervisor: AgentSupervisor, _ id: AgentID, tileID: UUID) -> ManagedAgentTileNSView {
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: tileID,
            kind: .managedAgent,
            title: "context-meter-check",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 420),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        tile.bindV2ComposerState(
            draftStore: AgentComposerDraftStore(
                applicationSupportDirectory: root.appendingPathComponent("drafts-\(tileID.uuidString)"),
                debounceInterval: 60),
            promptHistory: AgentPromptHistory())
        tile.attach(agentID: id, supervisor: supervisor)
        return tile
    }
    func meter(_ tile: ManagedAgentTileNSView) -> String {
        let row = tile.qaCompactStatusRow
        return "label '\(row.qaContextText)', fraction \(String(describing: row.qaContextFraction)), state \(row.qaContextState), threshold \(String(describing: row.qaContextThresholdFraction))"
    }

    let claudeTranslate: (@escaping @Sendable (AgentRuntimeObservation) -> Void) -> MeterReplayRunner.Translate = { observe in
        var translator = ClaudeEventTranslator()
        translator.onRuntimeObservation = observe
        return { translator.translate(line: $0) }
    }
    let claudeModel = AgentModelConfig.resolvedFromDefaults(harness: .claudeCode).model

    // (a) claude-opus-5-5 on claude 2.1.291, a model pi's models-store does not
    // list. Claude states its own window in `result.modelUsage`; the ring must
    // read it, and must read the PROMPT of the request in flight — not "8"
    // (one frame's input+output) mid-turn and not the run's sum at turn end.
    let opus = try meterFixture("claude-2.1.291-opus-turn.jsonl")
    guard opus.count == 35, opus[2].contains("\"message_start\""), opus[34].contains("\"modelUsage\"") else {
        throw Failure(description: "(a) fixture shape changed: message_start/result not where the witness reads them")
    }
    guard AgentModelCatalog.shared.contextWindow(for: "anthropic/claude-opus-5-5") == nil else {
        throw Failure(description: "(a) precondition: the window must NOT come from pi's models-store")
    }
    // A subagent's request: its prompt is another conversation's context and
    // must never reach the parent's ring.
    let subagentRequest = #"{"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":499997,"output_tokens":1}}},"session_id":"00000000-0000-4000-8000-000000000001","parent_tool_use_id":"toolu_fixture_child"}"#
    let opusTurn: [MeterReplayRunner.Step] = opus[0...2].map { .line($0) } + [.pause] + opus[3...].map { .line($0) }
    let opusTurnWithChild: [MeterReplayRunner.Step] = opus[0...2].map { .line($0) } + [.line(subagentRequest), .pause]
        + opus[3...].map { .line($0) }
    let claudeRoot = root.appendingPathComponent("meter-claude", isDirectory: true)
    let claudeRunner = MeterReplayRunner(
        turns: [opusTurn, opusTurnWithChild], freshTranslatorPerRun: true, makeTranslate: claudeTranslate)
    let claudeSupervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: claudeRoot), makeRunner: { _ in claudeRunner })
    let (claudeID, claudeTile) = spawnWithTile(claudeSupervisor, harness: .claudeCode, model: claudeModel)
    let prompt = 2 + 11_239 + 10_695
    guard claudeSupervisor.send("say hi", to: claudeID) else { throw Failure(description: "(a) send refused") }
    try await expectEventually("(a) first turn never reached message_start") { claudeRunner.isPaused }
    try await expectEventually("(a) mid-turn the ring must show the request's prompt tokens (21.9k) — \(meter(claudeTile))") {
        claudeTile.qaCompactStatusRow.qaContextText == "21.9k"
    }
    claudeRunner.resume()
    try await expectEventually("(a) turn end must divide the prompt by claude's stated 1M window — \(meter(claudeTile))") {
        near(claudeTile.qaCompactStatusRow.qaContextFraction, Double(prompt) / 1_000_000)
            && claudeTile.qaCompactStatusRow.qaContextText == "2%"
    }
    try await expectEventually("(a) first turn did not finish") {
        claudeRunner.finishedRunCount == 1 && !claudeSupervisor.isRunning(claudeID)
    }
    guard claudeSupervisor.send("again", to: claudeID) else { throw Failure(description: "(a) second send refused") }
    try await expectEventually("(a) second turn never reached message_start") { claudeRunner.isPaused }
    try await expectEventually("(a) the second turn's mid-turn reading must already be a percentage of the stated window, untouched by the subagent's request — \(meter(claudeTile))") {
        near(claudeTile.qaCompactStatusRow.qaContextFraction, Double(prompt) / 1_000_000)
    }
    claudeRunner.resume()
    try await expectEventually("(a) second turn did not finish") {
        claudeRunner.finishedRunCount == 2 && !claudeSupervisor.isRunning(claudeID)
    }
    // Relaunch: a supervisor restored over the same store meets the next
    // turn's first request with the window it learned before, not a bare count.
    let relaunchRunner = MeterReplayRunner(
        turns: [opusTurn], freshTranslatorPerRun: true, makeTranslate: claudeTranslate)
    let relaunched = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: claudeRoot), makeRunner: { _ in relaunchRunner })
    relaunched.restore()
    guard let relaunchedTileID = relaunched.records[claudeID]?.tileId else {
        throw Failure(description: "(a) relaunch lost the agent")
    }
    let relaunchedTile = attachTile(relaunched, claudeID, tileID: relaunchedTileID)
    guard relaunched.send("after relaunch", to: claudeID) else { throw Failure(description: "(a) relaunch send refused") }
    try await expectEventually("(a) relaunch turn never reached message_start") { relaunchRunner.isPaused }
    try await expectEventually("(a) after a relaunch the first request must still read against the stated window — \(meter(relaunchedTile))") {
        near(relaunchedTile.qaCompactStatusRow.qaContextFraction, Double(prompt) / 1_000_000)
            && relaunchedTile.qaCompactStatusRow.qaContextState == .known
    }
    relaunchRunner.resume()
    try await expectEventually("(a) relaunch turn did not finish") { !relaunched.isRunning(claudeID) }

    // The rest read their window from the fallback (pi's models-store), which
    // is exactly the case the provider-stated window must not be needed for.
    let piModel = AgentModelConfig.resolvedFromDefaults(harness: .pi).model
    AgentModelCatalog.shared.apply(contextWindows: [
        "anthropic/claude-fable-5": 200_000,
        piModel: 200_000,
    ])
    defer { AgentModelCatalog.shared.apply(contextWindows: [:]) }

    // (b) claude's own compaction, in turn, through the real supervisor delivery:
    // the boundary's post_tokens over the window becomes the reading. The epoch
    // stamp used to drop this exact snapshot, and the tile kept 13%.
    let compact = try meterFixture("claude-compact-boundary.jsonl")
    let preCompactionRequest = #"{"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-fable-5","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":26267,"output_tokens":1}}},"session_id":"00000000-0000-4000-8000-000000000001","parent_tool_use_id":null}"#
    let compactRunner = MeterReplayRunner(
        turns: [[.line(compact[0]), .line(preCompactionRequest), .line(compact[1]), .pause, .line(compact[2])]],
        freshTranslatorPerRun: true, makeTranslate: claudeTranslate)
    let compactSupervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("meter-compact")),
        makeRunner: { _ in compactRunner })
    let (compactID, compactTile) = spawnWithTile(compactSupervisor, harness: .claudeCode, model: claudeModel)
    guard compactSupervisor.send("compact", to: compactID) else { throw Failure(description: "(b) send refused") }
    try await expectEventually("(b) never reached the compacting status") { compactRunner.isPaused }
    try await expectEventually("(b) while compacting the ring keeps its last reading, dimmed — \(meter(compactTile))") {
        compactTile.qaCompactStatusRow.qaContextText == "13%"
            && compactTile.qaCompactStatusRow.qaContextState == .stale
            && compactSupervisor.turnSnapshot(for: compactID)?.state == .compacting
    }
    compactRunner.resume()
    try await expectEventually("(b) after the boundary the ring must show post_tokens (2140) over the window — \(meter(compactTile))") {
        near(compactTile.qaCompactStatusRow.qaContextFraction, 2_140.0 / 200_000)
            && compactTile.qaCompactStatusRow.qaContextState == .known
    }

    // (c) codex app-server, the production transport: `last` is the request,
    // `modelContextWindow` the window — live, mid-turn, never the cumulative
    // `total`.
    let codex = try meterFixture("codex-appserver-single-agent.jsonl")
    guard let firstUsage = codex.firstIndex(where: { $0.contains("thread/tokenUsage/updated") }) else {
        throw Failure(description: "(c) fixture has no tokenUsage notification")
    }
    let codexRunner = MeterReplayRunner(
        turns: [codex[...firstUsage].map { .line($0) } + [.pause] + codex[(firstUsage + 1)...].map { .line($0) }],
        freshTranslatorPerRun: true,
        makeTranslate: { observe in
            var translator = CodexAppServerEventTranslator()
            translator.onRuntimeObservation = observe
            return { translator.translate(line: $0) }
        })
    let codexSupervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("meter-codex")),
        makeRunner: { _ in codexRunner })
    let (codexID, codexTile) = spawnWithTile(
        codexSupervisor, harness: .codex, model: AgentModelConfig.resolvedFromDefaults(harness: .codex).model)
    guard codexSupervisor.send("hello", to: codexID) else { throw Failure(description: "(c) send refused") }
    try await expectEventually("(c) never reached the first tokenUsage notification") { codexRunner.isPaused }
    try await expectEventually("(c) mid-turn the ring must read last.totalTokens/modelContextWindow = 16138/258400 — \(meter(codexTile))") {
        near(codexTile.qaCompactStatusRow.qaContextFraction, 16_138.0 / 258_400)
    }
    codexRunner.resume()
    try await expectEventually("(c) turn end must read the LAST request (16509), not the cumulative total — \(meter(codexTile))") {
        near(codexTile.qaCompactStatusRow.qaContextFraction, 16_509.0 / 258_400)
    }

    // (d) pi: a settings-only snapshot (the policy, sent at every turn start)
    // must merge into the reading, never replace it; (e) compaction_end's
    // estimated `after` becomes the reading, marked as an estimate.
    let policy = AgentContextWindowSnapshot(
        automaticCompactionPolicy: AgentAutomaticCompactionPolicy(enabled: true, thresholdTokens: 160_000),
        observedAt: Date(), source: .unknown("pi-get-state"), freshness: .live)
    func piUsage(prompt: Int, at timestamp: Int) -> String {
        #"{"type":"message_end","message":{"role":"assistant","usage":{"input":1000,"output":50,"cacheRead":"# + "\(prompt - 1000)"
            + #","cacheWrite":0,"totalTokens":"# + "\(prompt + 50)" + #","cost":{"total":0.01}},"timestamp":"# + "\(timestamp)" + "}}"
    }
    let piRunner = MeterReplayRunner(
        turns: [
            [.event(.contextWindowUpdated(threadId: "pi", snapshot: policy)),
             .line(#"{"type":"session","id":"pi-meter"}"#), .line(#"{"type":"agent_start"}"#),
             .line(piUsage(prompt: 50_000, at: 1_786_000_000_000)), .line(#"{"type":"agent_settled"}"#)],
            [.event(.contextWindowUpdated(threadId: "pi", snapshot: policy)), .pause,
             .line(#"{"type":"agent_start"}"#),
             .line(piUsage(prompt: 60_000, at: 1_786_000_001_000)), .line(#"{"type":"agent_settled"}"#)],
            [.line(#"{"type":"agent_start"}"#), .line(#"{"type":"compaction_start","reason":"threshold"}"#), .pause,
             .line(#"{"type":"compaction_end","result":{"summary":"S","firstKeptEntryId":"e-1","tokensBefore":60000,"estimatedTokensAfter":12000}}"#),
             .line(#"{"type":"agent_settled"}"#)],
        ],
        freshTranslatorPerRun: false,
        makeTranslate: { observe in
            var translator = PiEventTranslator()
            translator.onRuntimeObservation = observe
            return { translator.translate(line: $0) }
        })
    let piSupervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("meter-pi")),
        makeRunner: { _ in piRunner })
    let (piID, piTile) = spawnWithTile(piSupervisor, harness: .pi, model: piModel)
    guard piSupervisor.send("one", to: piID) else { throw Failure(description: "(d) send refused") }
    try await expectEventually("(d) first pi turn must read 50k/200k with the 160k policy tick — \(meter(piTile))") {
        near(piTile.qaCompactStatusRow.qaContextFraction, 0.25)
            && near(piTile.qaCompactStatusRow.qaContextThresholdFraction, 0.8)
            && piRunner.finishedRunCount == 1 && !piSupervisor.isRunning(piID)
    }
    guard piSupervisor.send("two", to: piID) else { throw Failure(description: "(d) second send refused") }
    try await expectEventually("(d) second turn never started") { piRunner.isPaused }
    try await expectEventually("(d) the turn-start settings snapshot must not blank the ring — \(meter(piTile))") {
        near(piTile.qaCompactStatusRow.qaContextFraction, 0.25)
            && near(piTile.qaCompactStatusRow.qaContextThresholdFraction, 0.8)
    }
    piRunner.resume()
    try await expectEventually("(d) the next usage snapshot must keep the policy tick — \(meter(piTile))") {
        near(piTile.qaCompactStatusRow.qaContextFraction, 0.30)
            && near(piTile.qaCompactStatusRow.qaContextThresholdFraction, 0.8)
            && piRunner.finishedRunCount == 2 && !piSupervisor.isRunning(piID)
    }
    guard piSupervisor.send("three", to: piID) else { throw Failure(description: "(e) send refused") }
    try await expectEventually("(e) compaction never started") { piRunner.isPaused }
    try await expectEventually("(e) while pi compacts the ring keeps 30%, dimmed — \(meter(piTile))") {
        piTile.qaCompactStatusRow.qaContextText == "30%"
            && piTile.qaCompactStatusRow.qaContextState == .stale
    }
    piRunner.resume()
    try await expectEventually("(e) compaction_end must move the ring to the estimated 12k, marked ≈ — \(meter(piTile))") {
        near(piTile.qaCompactStatusRow.qaContextFraction, 0.06)
            && piTile.qaCompactStatusRow.qaContextText == "≈6%"
    }

    // (f) an in-turn compaction whose provider never reports a terminal: the
    // turn ending must end it. Left alone, "compacting" stuck until relaunch and
    // then paused the queue as an indeterminate operation.
    let stuckRunner = MeterReplayRunner(
        turns: [[.line(opus[0]), .line(compact[1]), .line(opus[34])]],
        freshTranslatorPerRun: true, makeTranslate: claudeTranslate)
    let stuckSupervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("meter-stuck")),
        makeRunner: { _ in stuckRunner })
    let (stuckID, _) = spawnWithTile(stuckSupervisor, harness: .claudeCode, model: claudeModel)
    guard stuckSupervisor.send("go", to: stuckID) else { throw Failure(description: "(f) send refused") }
    try await expectEventually("(f) turn did not finish") {
        stuckRunner.finishedRunCount == 1 && !stuckSupervisor.isRunning(stuckID)
    }
    try await expectEventually("(f) a completed turn must not leave the agent compacting (state \(String(describing: stuckSupervisor.turnSnapshot(for: stuckID)?.state)), journal \(String(describing: stuckSupervisor.records[stuckID]?.inFlightCompaction?.phase)))") {
        stuckSupervisor.turnSnapshot(for: stuckID)?.state != .compacting
            && stuckSupervisor.records[stuckID]?.inFlightCompaction == nil
    }
}
