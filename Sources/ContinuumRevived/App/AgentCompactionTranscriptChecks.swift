import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// A manual /compact must read as a quiet boundary in the transcript, on every
// harness, live and after relaunch — and the tile's live line must say what is
// happening while it runs.
//
// Observed live on 2026-10-13: Claude Code and Codex tiles both rendered the
// boundary as the raw fallback card "Unsupported content: compaction", and the
// tail read "Thinking · 3s" while the header said "Compacting context…".
// `CompactionRenderer` existed and its label was already gated — by calling
// `CompactionRenderer.label` directly, which is how the gate stayed green while
// production never registered the renderer at all.
//
// So this witness never names a renderer. It drives the REAL path: provider
// frames through each harness's real translator, out of a runner, through the
// supervisor, into an attached `ManagedAgentTileNSView`, and reads what the
// tile's transcript actually built. The persisted half decodes the exact shape
// `AgentTranscriptStore` wrote for a real Claude and Codex session and renders
// it through the production transcript list.

/// A runner that plays a manual compaction one STEP at a time, emitting what
/// that harness's real translator emits for the provider's frames — with the
/// operation id and manual trigger stamped the way every production runner
/// stamps them. Step 0 goes out at once; each later step waits for one
/// `release()`, so a witness can look at the tile between any two frames.
/// `failure`, when set, is thrown after the last step, as `PiRpcAgentRunner`
/// throws after pi's failed `compaction_end`.
private final class HeldCompactionRunner: AgentRunning, AgentCompactionRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let steps: @Sendable (AgentCompactionRequest) -> [[AgentRuntimeEvent]]
    private let failure: Error?
    private let seed: [AgentRuntimeEvent]
    private var entered = false
    private var emitted = 0
    private var stopped = false

    init(seed: [AgentRuntimeEvent] = [], failure: Error? = nil,
         steps: @escaping @Sendable (AgentCompactionRequest) -> [[AgentRuntimeEvent]]) {
        self.steps = steps
        self.failure = failure
        self.seed = seed
    }

    var compactionCapabilities: AgentCompactionCapabilities {
        AgentCompactionCapabilities(supportsManual: true, supportsFocus: true)
    }
    var keepsSessionAliveBetweenTurns: Bool { true }
    var canAcceptAnotherTurn: Bool { true }
    var compactEntered: Bool { lock.withLock { entered } }
    var stepsEmitted: Int { lock.withLock { emitted } }

    func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        let turnID = UUID().uuidString
        onEvent(.turnStarted(threadId: "provider", turnId: turnID))
        onEvent(.contentDelta(threadId: "provider", turnId: turnID, streamKind: .assistant, delta: "Seeded."))
        for event in seed { onEvent(event) }
        onEvent(.turnCompleted(threadId: "provider", turnId: turnID, outcome: .completed, errorMessage: nil))
    }

    func compact(
        _ request: AgentCompactionRequest,
        onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void
    ) throws {
        func stamped(_ event: AgentRuntimeEvent) -> AgentRuntimeEvent {
            guard case .compactionChanged(let threadId, var lifecycle) = event else { return event }
            lifecycle.operationID = request.operationID
            lifecycle.trigger = .manual
            return .compactionChanged(threadId: threadId, event: lifecycle)
        }
        let steps = steps(request)
        // Every production runner reports the operation running before the
        // provider answers; claude's translator has no start frame of its own.
        onEvent(.compactionChanged(threadId: "provider", event: AgentCompactionLifecycleEvent(
            operationID: request.operationID, phase: .running, trigger: .manual, provider: "runner")))
        for (index, step) in steps.enumerated() {
            if index > 0 {
                gate.wait()
                if lock.withLock({ stopped }) { throw AgentRunStopped(detail: "") }
            }
            for event in step { onEvent(stamped(event)) }
            lock.withLock { emitted = index + 1; if index == 0 { entered = true } }
        }
        if let failure { throw failure }
    }

    func release() { gate.signal() }
    func stop() {
        lock.withLock { stopped = true }
        gate.signal()
    }
    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
    func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {}
}

@MainActor
func runAgentCompactionTranscriptChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func fail(_ message: String) -> Failure { Failure(description: "compaction transcript: " + message) }
    func eventually(
        _ message: @autoclosure () -> String, timeout: TimeInterval = 8,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw fail(message())
    }
    func descendants(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func paintedRules(in layer: CALayer) -> [CALayer] {
        var found: [CALayer] = []
        if let colour = layer.backgroundColor, colour.alpha > 0,
           layer.bounds.height > 0, layer.bounds.height <= 3, layer.bounds.width >= 16 {
            found.append(layer)
        }
        for sublayer in layer.sublayers ?? [] { found += paintedRules(in: sublayer) }
        return found
    }

    /// What one rendered transcript says about its compaction rows.
    func assertBoundaryRows(in root: NSView, expected: [String], label: String) throws {
        if let tile = root as? ManagedAgentTileNSView, let canvas = tile.qaCanvasTranscript {
            // The drawn transcript: the same properties, read off the boundary
            // blocks it laid out — the label it drew, the width it drew it at
            // against the width it needs, and the rules painted beside it.
            let compactions = Set(tile.qaDocumentForChecks.entries.flatMap(\.blocks)
                .filter { $0.kind == .compaction }.map(\.id))
            let boundaries = canvas.qaPlacedBlockIDs.filter(compactions.contains).compactMap(canvas.qaBoundary(for:))
            guard boundaries.map(\.text) == expected else {
                throw fail("\(label): expected boundary rows \(expected), drew \(boundaries.map(\.text))")
            }
            for boundary in boundaries {
                guard boundary.width > 0 else { throw fail("\(label): a boundary row has no width") }
                guard boundary.drawnWidth + 0.5 >= boundary.neededWidth,
                      boundary.neededWidth + 32 <= boundary.width else {
                    throw fail("\(label): the boundary label is clipped — drawn \(boundary.drawnWidth)pt of the "
                        + "\(boundary.neededWidth)pt '\(boundary.text)' needs, in a \(boundary.width)pt row")
                }
                guard boundary.ruleRects.contains(where: { $0.height <= 3 && $0.width >= 16 }) else {
                    throw fail("\(label): the boundary row paints no divider line — it reads as stray "
                        + "text, not as the point the context was cut")
                }
            }
            return
        }
        let views = descendants(in: root)
        let unknown = views.compactMap { $0 as? AgentUnknownBlockView }
            .map(\.summaryLabel.stringValue)
            .filter { $0.contains("compaction") }
        guard unknown.isEmpty else {
            throw fail("\(label): the boundary rendered as the raw fallback card \(unknown) — "
                + "`.compaction` is not registered in AgentBlockRendererRegistry.production")
        }
        let boundaries = views.compactMap { $0 as? CompactionBoundaryView }
        let texts = boundaries.map { ($0.accessibilityLabel() ?? "") }
        guard texts == expected else {
            throw fail("\(label): expected boundary rows \(expected), rendered \(texts)")
        }
        for boundary in boundaries {
            guard boundary.bounds.width > 0, boundary.bounds.height > 0 else {
                throw fail("\(label): a boundary row has no size (\(boundary.frame))")
            }
            // Live 2026-10-13, a ~540pt Codex tile: "Context compacted manu…"
            // with the whole row empty around it.
            guard boundary.qaLabelText == boundary.accessibilityLabel(),
                  boundary.qaLabelDrawnWidth + 0.5 >= boundary.qaLabelNeededWidth,
                  boundary.qaLabelNeededWidth + 32 <= boundary.bounds.width else {
                throw fail("\(label): the boundary label is clipped — drawn \(boundary.qaLabelDrawnWidth)pt of the "
                    + "\(boundary.qaLabelNeededWidth)pt '\(boundary.qaLabelText)' needs, in a \(boundary.bounds.width)pt row")
            }
            guard let layer = boundary.layer, !paintedRules(in: layer).isEmpty else {
                throw fail("\(label): the boundary row paints no divider line — it reads as stray "
                    + "text, not as the point the context was cut")
            }
        }
    }

    // MARK: Relaunch — each provider's own session log, through its real reader.
    //
    // Seen live 2026-10-13: after relaunch a Claude tile rehydrated from
    // `~/.claude/projects/<cwd>/<session>.jsonl` showed the compaction as three
    // raw user bubbles — the `isMeta` local-command caveat, the
    // `<command-name>/compact</command-name>` record and the
    // `<local-command-stdout>` echo — and the boundary lost its counts because
    // the log spells them `compactMetadata.preTokens`, not the live stream's
    // `compact_metadata.pre_tokens`. Fixture lines copy the real record shapes
    // from that session file; private text is replaced.
    let claudeLog = [
        #"{"type":"queue-operation","operation":"enqueue","sessionId":"s"}"#,
        #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Remember the code word FIXTURE-1. Reply with only OK."},"uuid":"u1","sessionId":"s"}"#,
        #"{"type":"attachment","uuid":"att1","sessionId":"s"}"#,
        #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"OK"}]},"uuid":"a1","sessionId":"s"}"#,
        #"{"type":"last-prompt","sessionId":"s"}"#,
        #"{"parentUuid":null,"logicalParentUuid":"a1","isSidechain":false,"type":"system","subtype":"compact_boundary","content":"Conversation compacted","isMeta":false,"uuid":"claude-relaunch-boundary","level":"info","compactMetadata":{"trigger":"manual","preTokens":22534,"durationMs":5508,"postTokens":1515,"cumulativeDroppedTokens":21019},"sessionId":"s"}"#,
        #"{"parentUuid":"claude-relaunch-boundary","isSidechain":false,"type":"user","message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation.\n\nSummary:\nPRIVATE SUMMARY"},"isVisibleInTranscriptOnly":true,"isCompactSummary":true,"uuid":"sum1","sessionId":"s"}"#,
        #"{"parentUuid":"sum1","isSidechain":false,"type":"user","message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>"},"isMeta":true,"uuid":"cav1","sessionId":"s"}"#,
        #"{"parentUuid":"cav1","isSidechain":false,"type":"user","message":{"role":"user","content":"<command-name>/compact</command-name>\n            <command-message>compact</command-message>\n            <command-args></command-args>"},"uuid":"cmd1","sessionId":"s"}"#,
        #"{"parentUuid":"cmd1","isSidechain":false,"type":"user","message":{"role":"user","content":"<local-command-stdout>Compacted </local-command-stdout>"},"uuid":"out1","sessionId":"s"}"#,
        #"{"parentUuid":"out1","isSidechain":false,"type":"user","message":{"role":"user","content":"What was the code word? Reply with only the word."},"uuid":"u2","sessionId":"s"}"#,
        #"{"parentUuid":"u2","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"FIXTURE-1"}]},"uuid":"a2","sessionId":"s"}"#,
    ]
    // The rollout shape `CodexSessionTranscriptReader` reads, with a persisted
    // compaction item between turns.
    let codexLog = [
        #"{"type":"event_msg","payload":{"type":"user_message","message":"Remember the code word FIXTURE-2."}}"#,
        #"{"type":"event_msg","payload":{"type":"agent_message","message":"OK"}}"#,
        #"{"type":"response_item","payload":{"type":"compaction","id":"codex-relaunch-boundary","encrypted_content":"PRIVATE"}}"#,
        #"{"type":"event_msg","payload":{"type":"user_message","message":"What was the code word?"}}"#,
        #"{"type":"event_msg","payload":{"type":"agent_message","message":"FIXTURE-2"}}"#,
    ]
    // Pi's append-only session file: the compaction entry carries its summary,
    // which must never surface, and only `tokensBefore`. The compaction line
    // has the exact field set of a real pi entry (a pi session compacted on
    // 2026-10-13: id/parentId/timestamp/summary/firstKeptEntryId/tokensBefore/
    // details/usage/fromHook), summary text replaced.
    let piLog = [
        #"{"type":"session","id":"pi-relaunch"}"#,
        #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Remember the code word FIXTURE-3."}]}}"#,
        #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"OK"}]}}"#,
        #"{"type":"compaction","id":"20e81b12","parentId":"c244d79e","timestamp":"2026-10-14T02:14:09.543Z","summary":"PRIVATE SUMMARY","firstKeptEntryId":"8d8a81e1","tokensBefore":26268,"details":{"readFiles":[],"modifiedFiles":[]},"usage":{"input":221552,"output":383,"cacheRead":0,"cacheWrite":0,"reasoning":69,"totalTokens":221935},"fromHook":false}"#,
        #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"What was the code word?"}]}}"#,
        #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"FIXTURE-3"}]}}"#,
    ]
    let relaunches: [(String, RehydratedTranscript, String, [String])] = [
        ("Claude Code", ClaudeSessionTranscriptReader.parse(lines: claudeLog, threadId: "relaunch"),
         "Context compacted manually · 22.5k → 1.5k",
         ["Remember the code word FIXTURE-1. Reply with only OK.", "What was the code word? Reply with only the word."]),
        // Neither log records manual vs automatic, nor (Codex) any size.
        ("Codex", CodexSessionTranscriptReader.parse(lines: codexLog, threadId: "relaunch"),
         "Context compacted", ["Remember the code word FIXTURE-2.", "What was the code word?"]),
        ("Pi", PiSessionTranscriptReader.parse(lines: piLog, threadId: "relaunch"),
         "Context compacted", ["Remember the code word FIXTURE-3.", "What was the code word?"]),
    ]
    for (name, transcript, expected, prompts) in relaunches {
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "compaction-relaunch",
            frame: TileFrame(x: 0, y: 0, width: 640, height: 720),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 640, height: 720)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tile
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        tile.renderRehydratedPreviousSession(transcript)
        let userTexts = tile.qaDocumentForChecks.entries.filter { $0.role == .user }
            .map { String(describing: $0.blocks) }
        let leaked = userTexts.filter {
            $0.contains("<local-command") || $0.contains("<command-name>") || $0.contains("<command-message>")
                || $0.contains("being continued from a previous conversation") || $0.contains("PRIVATE")
        }
        guard leaked.isEmpty else {
            throw fail("\(name) relaunch: provider bookkeeping rendered as user bubbles: \(leaked)")
        }
        guard userTexts.count == prompts.count,
              zip(userTexts, prompts).allSatisfy({ $0.contains($1) }) else {
            throw fail("\(name) relaunch: expected exactly the user's own prompts \(prompts), restored \(userTexts)")
        }
        guard let block = tile.qaDocumentForChecks.entries.flatMap(\.blocks).first(where: { $0.kind == .compaction }) else {
            throw fail("\(name) relaunch: the compaction boundary did not survive rehydration")
        }
        try await eventually("\(name) relaunch: the compaction row never reached the list") {
            tile.layoutSubtreeIfNeeded()
            return tile.qaDisplayedBlockIDs.contains(block.id)
        }
        tile.layoutSubtreeIfNeeded()
        if let list = tile.qaTranscriptForChecks {
            // The boundary sits mid-history; bring every row into the window.
            list.scrollView.contentView.scroll(to: .zero)
            list.layout()
            list.collectionView.layout()
        }
        try assertBoundaryRows(in: tile, expected: [expected], label: "\(name) relaunch")
    }

    // MARK: Live — each harness's real translator, through the supervisor, into the tile.

    let now: @Sendable () -> Date = { Date(timeIntervalSinceReferenceDate: 813_600_000) }
    struct LiveCase {
        let harness: AgentHarness
        let label: String
        let expected: String
        var seed: [AgentRuntimeEvent] = []
        var failure: Error?
        let steps: @Sendable (AgentCompactionRequest) -> [[AgentRuntimeEvent]]
    }
    // REAL codex-cli 0.159.3 app-server frames for `thread/compact/start`
    // (captured 2026-10-13; the same capture `CodexAppServerRunnerChecks` 2f
    // replays), one notification per step. The seed turn's usage is that
    // session's single prior turn: `last` equals the `total` the compaction
    // turn reports (16,150 in + 5 out), in its 475,000 window.
    let codexSeedUsage = #"{"method":"thread/tokenUsage/updated","params":{"threadId":"01a13824-f3a1-7281-adf7-2982d6882465","turnId":"01a13824-f3a5-7f10-9a4e-4f3f2b0c1d00","tokenUsage":{"total":{"totalTokens":16155,"inputTokens":16150,"cachedInputTokens":13184,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"last":{"totalTokens":16155,"inputTokens":16150,"cachedInputTokens":13184,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"modelContextWindow":475000}}}"#
    let codexCompactionFrames = [
        #"{"method":"thread/status/changed","params":{"threadId":"01a13824-f3a1-7281-adf7-2982d6882465","status":{"type":"active","activeFlags":[]}}}"#,
        #"{"method":"turn/started","params":{"threadId":"01a13824-f3a1-7281-adf7-2982d6882465","turn":{"id":"01a13825-12be-7782-9fce-96d10cb8ba2f","items":[],"itemsView":"notLoaded","status":"inProgress","error":null,"startedAt":1791943316,"completedAt":null,"durationMs":null}}}"#,
        #"{"method":"item/started","params":{"item":{"type":"contextCompaction","id":"01a13825-12d5-7fd0-89d6-b3e61266c758"},"threadId":"01a13824-f3a1-7281-adf7-2982d6882465","turnId":"01a13825-12be-7782-9fce-96d10cb8ba2f","startedAtMs":1791943316181}}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"01a13824-f3a1-7281-adf7-2982d6882465","turnId":"01a13825-12be-7782-9fce-96d10cb8ba2f","tokenUsage":{"total":{"totalTokens":16155,"inputTokens":16150,"cachedInputTokens":13184,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"last":{"totalTokens":6072,"inputTokens":0,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0},"modelContextWindow":475000}}}"#,
        #"{"method":"item/completed","params":{"item":{"type":"contextCompaction","id":"01a13825-12d5-7fd0-89d6-b3e61266c758"},"threadId":"01a13824-f3a1-7281-adf7-2982d6882465","turnId":"01a13825-12be-7782-9fce-96d10cb8ba2f","completedAtMs":1791943325128}}"#,
    ]
    var codexSeedTranslator = CodexAppServerEventTranslator(now: now)
    let codexSeed = codexSeedTranslator.translate(line: codexSeedUsage)
    // pi's REAL rpc answer to `compact` on a session with nothing to summarize
    // (captured from `pi --mode rpc`, 2026-10-13).
    let piRefusalFrames = [
        #"{"type":"compaction_start","reason":"manual"}"#,
        #"{"type":"compaction_end","reason":"manual","aborted":false,"willRetry":false,"errorMessage":"Compaction failed: Nothing to compact (session too small)"}"#,
    ]
    let harnesses: [LiveCase] = [
        LiveCase(harness: .claudeCode, label: "Claude Code", expected: "Context compacted manually · 154k → 22k", steps: { _ in
            var claude = ClaudeEventTranslator(runToken: "compaction-transcript", now: now)
            _ = claude.translate(line: #"{"type":"system","subtype":"init","session_id":"claude-session","model":"claude-fixture"}"#)
            return [[], claude.translate(line: #"{"type":"system","subtype":"compact_boundary","session_id":"claude-session","uuid":"claude-boundary","compact_metadata":{"trigger":"manual","pre_tokens":154000,"post_tokens":22000}}"#)]
        }),
        // Codex states no before-count of its own: the boundary carries the
        // meter's last provider reading from before the compaction (16,155)
        // and codex's in-compaction recount as the estimated after (≈6,072).
        // `CodexAgentRunner.compact` forwards every frame but the compaction
        // turn's own `turn/started`/`turn/completed`, so those are dropped here.
        LiveCase(harness: .codex, label: "Codex", expected: "Context compacted manually · 16.2k → ≈6.1k",
                 seed: codexSeed, steps: { request in
            var codex = CodexAppServerEventTranslator(
                compactionOperationID: request.operationID, compactionTrigger: .manual, now: now)
            return codexCompactionFrames.map { line in
                codex.translate(line: line).filter {
                    switch $0 {
                    case .turnStarted, .turnCompleted: return false
                    default: return true
                    }
                }
            }
        }),
        // Pi's after-size is its own estimate, and says so.
        LiveCase(harness: .pi, label: "Pi", expected: "Context compacted manually · 99k → ≈19k", steps: { _ in
            var pi = PiEventTranslator(now: now)
            _ = pi.translate(line: #"{"type":"session","id":"pi-session"}"#)
            let start = pi.translate(line: #"{"type":"compaction_start","reason":"manual"}"#)
            let end = pi.translate(line: #"{"type":"compaction_end","result":{"firstKeptEntryId":"entry-9","tokensBefore":99000,"estimatedTokensAfter":19000}}"#)
            return [start, end]
        }),
        // 2026-10-13, preview app: a Pi tile's /compact painted a red "Context
        // compaction failed" and nothing else, while pi had said why. The
        // runner throws after the failed `compaction_end`, exactly as
        // `PiRpcAgentRunner.compact` does.
        LiveCase(harness: .pi, label: "Pi refused", expected: "Context compaction failed · Nothing to compact yet",
                 failure: PiRpcAgentRunner.RunError.commandFailed(
                    command: "compact", message: "Compaction failed: Nothing to compact (session too small)"),
                 steps: { _ in
            var pi = PiEventTranslator(now: now)
            return piRefusalFrames.map { pi.translate(line: $0) }
        }),
        // The shared catch path every runner reaches when no terminal frame
        // arrived: pi's rpc `response` error, as `PiRpcAgentRunner.compact`
        // wraps it when `sendAndAwait` fails.
        LiveCase(harness: .pi, label: "Pi refused (response only)", expected: "Context compaction failed · Nothing to compact yet",
                 failure: PiRpcAgentRunner.RunError.commandFailed(
                    command: "compact", message: "launchFailed(Nothing to compact (session too small))"),
                 steps: { _ in [[]] }),
    ]
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("array-compaction-transcript-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var summary: [String] = []

    for live in harnesses {
        let harness = live.harness
        let expected = live.expected
        let benchRoot = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let work = benchRoot.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let runner = HeldCompactionRunner(seed: live.seed, failure: live.failure, steps: live.steps)
        // ONE draft store for the supervisor and the tile, as production wires it.
        let drafts = AgentComposerDraftStore(applicationSupportDirectory: benchRoot, debounceInterval: 0)
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: benchRoot),
            makeRunner: { _ in runner },
            submissionRecoveryStore: drafts)
        defer { runner.release(); supervisor.stopAll() }
        let config = AgentModelConfig.resolvedFromDefaults(harness: harness)
        let tileID = UUID()
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: harness,
                                  model: config.model, thinking: config.thinking, tileId: tileID)
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: tileID, kind: .managedAgent, title: "compaction-transcript",
            frame: TileFrame(x: 0, y: 0, width: 540, height: 520),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 540, height: 520)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 520),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tile
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        tile.bindV2ComposerState(draftStore: drafts, promptHistory: AgentPromptHistory())
        tile.attach(agentID: id, supervisor: supervisor)

        guard supervisor.send("seed", to: id) else { throw fail("\(harness): seed turn refused") }
        try await eventually("\(harness): seed turn did not settle") { !supervisor.isRunning(id) }
        // Positive control for the footer assertion below: the settled seed
        // turn does show its footer before any compaction.
        try await eventually("\(harness): the settled seed turn never showed 'Worked for …' (read '\(tile.qaTailStatusText)')") {
            tile.qaRefreshThinkingIndicatorForChecks()
            return tile.qaTailStatusText.hasPrefix("Worked for")
        }
        // Typed into the tile's REAL composer, the way a person runs it — every
        // edit saves through `composerTextDidChange` into the shared draft store.
        // Seen live 2026-10-13: a Codex tile compacted, and after relaunch its
        // composer came back reading "/compact " from `agent-composer-drafts`.
        guard let composer = tile.qaComposerForChecks else { throw fail("\(harness): the tile has no composer") }
        try await eventually("\(harness): the composer never offered Send after the seed turn") { tile.qaV2CanSend }
        // Let the attach-time draft restore settle so it cannot overwrite the typing.
        try await Task.sleep(for: .milliseconds(200))
        // Codex goes through the picker row (the live repro left "/compact "
        // with the row's trailing space); the others type the bare command.
        let typed = harness == .codex ? "/comp" : "/compact"
        composer.textView.string = typed
        composer.textView.setSelectedRange(NSRange(location: (typed as NSString).length, length: 0))
        composer.composerTextDidChange(composer.textView)
        if harness == .codex {
            let invocation = AgentCommandInvocation(descriptorID: "array:compact", name: "compact", surface: .array)
            composer.qaAcceptCompletionForChecks(
                AgentCompletion(id: "array:compact", title: "compact", insertionText: "/compact",
                                payload: .command(invocation)),
                replacementRange: NSRange(location: 0, length: (typed as NSString).length))
        }
        var persisted: String?
        for _ in 0..<100 where persisted?.trimmingCharacters(in: .whitespaces) != "/compact" {
            try await Task.sleep(for: .milliseconds(20))
            await drafts.flush(agentID: id)
            persisted = await drafts.load(for: id)?.text
        }
        guard persisted?.trimmingCharacters(in: .whitespaces) == "/compact" else {
            throw fail("\(harness): the typed /compact never reached the draft store (read '\(persisted ?? "nil")', "
                + "composer '\(composer.textView.string)') — this witness would not cross the defect")
        }
        composer.composerRequestedSend(composer.textView)
        try await eventually("\(harness): the runner never entered compaction") { runner.compactEntered }

        // While it runs, the live line names the operation — never "Thinking" —
        // and it stays there, ticking, through EVERY provider frame until the
        // boundary lands, including long after the location's 30s "what" has
        // gone stale. Seen live 2026-10-13 on Codex: "Compacting context… ·
        // 14s", then the line vanished while the header still said
        // "Compacting context…" and Stop still showed — it looked hung.
        let stepCount = live.steps(AgentCompactionRequest()).count
        for step in 1..<max(stepCount, 1) {
            for offset: TimeInterval in [0, 31, 125] {
                try await eventually(
                    "\(live.label): before frame \(step) of \(stepCount - 1), \(Int(offset))s into the compaction, the tile's live line "
                        + "read '\(tile.qaTailStatusText)' — it must keep saying 'Compacting context…' until the boundary lands"
                ) {
                    if offset > 0 { tile.qaRefreshLocation(at: Date().addingTimeInterval(offset)) }
                    return tile.qaTailStatusText.hasPrefix("Compacting context…")
                }
            }
            runner.release()
            try await eventually("\(live.label): frame \(step) was never delivered") { runner.stepsEmitted > step }
            try await Task.sleep(for: .milliseconds(30))
        }

        // The collection view realises a newly inserted row on its own layout
        // pass; give it a few before reading the rendered row.
        try? await eventually("\(live.label): boundary row realised", timeout: 2) {
            tile.layoutSubtreeIfNeeded()
            if let list = tile.qaTranscriptForChecks {
                list.layout()
                list.collectionView.layout()
            }
            if let canvas = tile.qaCanvasTranscript {
                return canvas.qaPlacedBlockIDs.contains { id in
                    tile.qaDocumentForChecks.entries.flatMap(\.blocks).contains { $0.id == id && $0.kind == .compaction }
                }
            }
            return descendants(in: tile).contains { $0 is CompactionBoundaryView }
        }
        try assertBoundaryRows(in: tile, expected: [expected], label: "\(live.label) live")
        // A row first laid out narrow must re-lay its label when it widens —
        // the label and rules are framed by hand, and an engine-driven resize
        // does not by itself re-run `layout()` on the boundary view.
        for width: CGFloat in [260, 540] {
            window.setContentSize(NSSize(width: width, height: 520))
            tile.frame = NSRect(x: 0, y: 0, width: width, height: 520)
            tile.layoutSubtreeIfNeeded()
            tile.displayIfNeeded()
        }
        try assertBoundaryRows(in: tile, expected: [expected], label: "\(live.label) live, after a narrow→wide resize")
        // The seed turn's settled "Worked for Ns" is the tail row, pinned to the
        // document's foot — under the boundary it reads as the compaction's
        // duration. A boundary after a settled turn retires it, exactly as the
        // next turn starting does.
        try await eventually(
            "\(harness): after the boundary the tail still reads '\(tile.qaTailStatusText)' beneath it — "
                + "the previous turn's footer now reads as the compaction's duration"
        ) {
            tile.qaRefreshThinkingIndicatorForChecks()
            return !tile.qaTailStatusText.hasPrefix("Worked for")
        }
        // What the next launch reads back: a fresh store over the same directory.
        await drafts.flush(agentID: id)
        let relaunched = AgentComposerDraftStore(applicationSupportDirectory: benchRoot, debounceInterval: 0)
        let leftover = await relaunched.load(for: id)?.text ?? ""
        guard leftover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              composer.textView.string.isEmpty else {
            throw fail("\(harness): the dispatched /compact survived as a draft — on screen '\(composer.textView.string)', "
                + "after relaunch '\(leftover)'")
        }
        summary.append("\(live.label) '\(expected)'")
    }

    // MARK: Relaunch — the exact block shape `AgentTranscriptStore` persisted.

    // Copied from real `snapshot.json` files written by the preview app on
    // 2026-10-13 (a Claude and a Codex manual /compact), ids shortened.
    let persistedBlocks = [
        #"{"revision":0,"kind":"compaction","id":"item:claude/child-key:content","payload":{"compaction":{"_0":{"boundaryID":"abe3666d","phase":"succeeded","automaticCompaction":false,"provider":"claude","trigger":"manual","preTokens":22534,"postTokens":1515}}},"children":[]}"#,
        #"{"kind":"compaction","id":"item:codex/child-key:content","revision":0,"payload":{"compaction":{"_0":{"phase":"succeeded","provider":"codex","trigger":"manual","automaticCompaction":false,"boundaryID":"01a13822"}}},"children":[]}"#,
    ]
    let decoded = try persistedBlocks.map { try JSONDecoder().decode(AgentBlock.self, from: Data($0.utf8)) }
    guard decoded.allSatisfy({ block in
        if case .compaction = block.payload { return block.kind == .compaction }
        return false
    }) else {
        throw fail("persisted compaction blocks no longer decode as `.compaction`: \(decoded.map(\.kind.rawValue))")
    }
    func nodeID(_ suffix: String) -> AgentNodeID { AgentNodeID(rawValue: "persisted-compaction-\(suffix)")! }
    let entries: [AgentEntry] = [
        AgentEntry(id: nodeID("u1"), revision: 1, role: .user, provenance: .localPrompt(promptID: "persisted"),
                   lifecycle: .finished,
                   blocks: [AgentBlock(id: nodeID("u1-t"), revision: 1, kind: .paragraph, payload: .paragraph([.text("Summarise the plan.")]))]),
        AgentEntry(id: nodeID("a1"), revision: 1, role: .assistant,
                   provenance: .providerItem(provider: "fixture", itemID: "a1"), lifecycle: .finished,
                   blocks: [AgentBlock(id: nodeID("a1-t"), revision: 1, kind: .paragraph, payload: .paragraph([.text("Done.")]))]),
    ] + decoded.enumerated().map { index, block in
        AgentEntry(id: nodeID("c\(index)"), revision: 1, role: .system,
                   provenance: .providerItem(provider: "fixture", itemID: "c\(index)"), lifecycle: .finished,
                   blocks: [block])
    }
    let document = AgentDocument(version: 1, entries: entries)
    let list = AgentTranscriptListView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSView(frame: window.contentRect(forFrameRect: window.frame))
    host.addSubview(list)
    window.contentView = host
    list.frame = host.bounds
    list.layoutSubtreeIfNeeded()
    try list.apply(document: document, patch: AgentDocumentPatch(
        fromVersion: 0, toVersion: document.version, inserted: document.entries.flatMap(\.blocks).map(\.id)))
    list.layout()
    list.collectionView.layout()
    try assertBoundaryRows(
        in: list,
        expected: ["Context compacted manually · 22.5k → 1.5k", "Context compacted manually"],
        label: "persisted snapshot")

    print("AgentCompactionTranscriptChecks passed: live boundary rows for \(summary.joined(separator: ", ")); "
        + "the live line reads 'Compacting context…' through every provider frame and past the location's 30s expiry; a refused compaction says why; a dispatched /compact leaves no draft; persisted Claude/Codex blocks render "
        + "as boundary rows after relaunch; Claude/Codex/Pi session-log rehydration restores only the user's own "
        + "prompts and one boundary row each")
}
