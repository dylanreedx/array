import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A board card dropped on an agent and sent with nothing typed — the film's
/// RST-42 shot, where the codex tile showed no user turn at all. Driven end to
/// end through production seams: a supervisor-owned agent of each harness, a
/// real tile attached to it, `prepareBoardTask` (the drop), the Send button,
/// and a runner whose events are that provider's own frames through its
/// production translator. The turn must survive as a task card above the reply.
@MainActor
func checkTaskOnlySendKeepsItsTurn(
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-task-only-send-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let reply = "Each line is rounded before the discount, so a cent goes missing."
    let card = BoardCard(
        id: UUID(), columnId: UUID(), position: FracIndex(value: 0.5),
        title: "RST-42 Cart total is off by a cent",
        body: "A 10% discount on two Autumn blends shows $32.39. It should be $32.40.",
        createdAt: Date(), updatedAt: Date()
    )
    func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    let frames: [(AgentHarness, () -> [AgentRuntimeEvent])] = [
        (.claudeCode, {
            var translator = ClaudeEventTranslator()
            return translator.translate(stream: [
                json(["type": "system", "subtype": "init", "session_id": "11111111-2222-3333-4444-555555555555"]),
                json(["type": "stream_event", "event": [
                    "type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": reply]]]),
                json(["type": "result", "subtype": "success", "is_error": false]),
            ])
        }),
        (.codex, {
            var translator = CodexAppServerEventTranslator()
            return translator.translate(stream: [
                json(["method": "thread/started", "params": ["thread": ["id": "codex-thread"]]]),
                json(["method": "turn/started", "params": ["threadId": "codex-thread", "turn": ["id": "codex-turn"]]]),
                json(["method": "item/agentMessage/delta", "params": [
                    "threadId": "codex-thread", "turnId": "codex-turn", "itemId": "msg-1", "delta": reply]]),
                json(["method": "turn/completed", "params": [
                    "threadId": "codex-thread", "turn": ["id": "codex-turn", "status": "completed"]]]),
            ])
        }),
        (.pi, {
            var translator = PiEventTranslator()
            return translator.translate(stream: [
                json(["type": "agent_start"]), json(["type": "turn_start"]),
                json(["type": "message_update", "assistantMessageEvent": [
                    "type": "text_delta", "contentIndex": 0, "delta": reply]]),
                json(["type": "turn_end", "message": ["role": "assistant"]]),
                json(["type": "agent_settled"]),
            ])
        }),
    ]

    var checked: [String] = []
    for (harness, events) in frames {
        let support = root.appendingPathComponent(harness.rawValue.replacingOccurrences(of: " ", with: "-"), isDirectory: true)
        let store = AgentStore(applicationSupportDirectory: support)
        let script = events()
        let runner = ScriptedAgentRunner(script: script)
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in runner })
        let tileID = UUID()
        // Each harness at its own resolved model, as a real spawn records it.
        let harnessConfig = AgentModelConfig.resolvedFromDefaults(harness: harness)
        let agentID = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: harness,
                                       model: harnessConfig.model, thinking: harnessConfig.thinking, tileId: tileID)
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: tileID, kind: .managedAgent, title: "task-only-\(harness.rawValue)",
            frame: TileFrame(x: 0, y: 0, width: 560, height: 520),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        ))
        tile.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
        // `TileSpawner`'s bootstrap line, as the film's codex tile showed it.
        tile.ingest(.sessionStateChanged(.ready))
        tile.ingest(.contentDelta(threadId: "thread-main", turnId: "bootstrap", streamKind: .assistant,
                                  delta: "Ready. Type a prompt below to run the model in this tile."))
        let attachments = AgentComposerAttachmentStore(applicationSupportDirectory: support)
        let drafts = AgentComposerDraftStore(applicationSupportDirectory: support, attachmentStore: attachments)
        tile.bindV2ComposerState(draftStore: drafts, promptHistory: AgentPromptHistory(), attachmentStore: attachments)
        tile.attach(agentID: agentID, supervisor: supervisor)
        guard await waitUntil(timeout: 5, pollInterval: 0.02, { tile.qaV2CanSend }) else {
            throw fail("task-only send/\(harness.rawValue): the attached tile never became send-capable")
        }
        // The drop: a card assigned to this agent prepares its composer.
        try await tile.prepareBoardTask(
            boardID: UUID(), card: card, revision: 1,
            store: BoardAttachmentStore(projectRoot: support),
            focusComposer: false, confirmReplacement: false)
        tile.qaPressSendForChecks()
        guard await waitUntil(timeout: 5, pollInterval: 0.02, { runner.completedRuns == 1 }) else {
            throw fail("task-only send/\(harness.rawValue): Send never reached the runner (runs \(runner.runCount)); "
                + "snapshot \(String(describing: supervisor.turnSnapshot(for: agentID)?.state)), action \(tile.qaV2ActionTitle ?? "nil"), "
                + "entries \(tile.qaDocumentForChecks.entries.map { "\($0.role.rawValue):\($0.blocks.map(\.kind.rawValue))" })")
        }
        guard runner.agentPrompts.first?.text.contains("observedRevision: 1") == true else {
            throw fail("task-only send/\(harness.rawValue): the agent did not receive the task envelope: \(runner.agentPrompts)")
        }
        func hasReply(_ entry: AgentEntry) -> Bool {
            entry.role != .user && entry.blocks.contains { block in
                guard case let .paragraph(inlines) = block.payload else { return false }
                return inlines.contains { if case let .text(t) = $0 { return t.contains("cent goes missing") }; return false }
            }
        }
        guard await waitUntil(timeout: 5, pollInterval: 0.02, {
            tile.qaDocumentForChecks.entries.contains(where: hasReply)
        }) else {
            throw fail("task-only send/\(harness.rawValue): the provider's reply never reached the tile")
        }
        let entries = tile.qaDocumentForChecks.entries
        let shape = entries.map { "\($0.role.rawValue):\($0.blocks.map(\.kind.rawValue))" }
        guard let userIndex = entries.firstIndex(where: { $0.role == .user }),
              let replyIndex = entries.firstIndex(where: hasReply), userIndex < replyIndex,
              entries[userIndex].blocks.map(\.kind) == [.taskReference] else {
            throw fail("task-only send/\(harness.rawValue): no task turn before the reply; entries \(shape)")
        }
        guard let transcript = tile.qaTranscriptForChecks else {
            throw fail("task-only send/\(harness.rawValue): the tile has no transcript")
        }
        tile.qaFlushStreamingMarkupForChecks()
        transcript.flushPendingVisualUpdate()
        guard transcript.qaDisplayedRowIDsForChecks.contains(entries[userIndex].blocks[0].id) else {
            throw fail("task-only send/\(harness.rawValue): the task turn is not among the displayed rows; entries \(shape)")
        }
        checked.append(harness.rawValue)
        supervisor.stop(agentID)
    }
    return "a task-only board send kept its task turn above the reply for \(checked.joined(separator: ", "))"
}
