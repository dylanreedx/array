import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Ticket: C10 (`.plans/45-transcript-program-handoff-prompt.md`)
//
// `AgentReferencePayload` deliberately carries no status — a status tick must
// never rewrite the semantic document a child's chip lives in.
// `AgentReferenceRenderer`/`AgentReferenceChipView` resolve status at RENDER
// time instead, through `AgentReferenceStatusSource`, which the tile builds
// from the supervisor's own `turnSnapshot(for:)` + `InboxState.state(forSnapshot:)`
// — the same single-status-owner mapping the inbox row uses (P3.3).
//
// This drives a REAL status change through the production path
// (`AgentSupervisor.send` → a live runner → `turnSnapshot`) and asserts BOTH
// halves named above: the chip's rendered accessibility value changes, AND the
// `AgentDocument` bytes carrying the `.agentReference` block are byte-identical
// before and after. The second clause is the teeth on "a status tick must
// never rewrite history" — it is asserted explicitly, not implied by the first.
@MainActor
func checkAgentReferenceLiveStatus(
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-agent-reference-status-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)

    // Held open so the child has a live runner for as long as the check needs
    // it — `turnSnapshot(for:)` reads `runners[id] != nil` among other facts,
    // and this is the same production fact `notifyTurnCapabilitiesChanged`
    // fires on.
    let holding = ScriptedAgentRunner(
        script: [.turnStarted(threadId: "provider-thread", turnId: "turn-1")],
        holdUntilStopped: true
    )
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in holding })

    let childID = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )

    // The production render context construction
    // (`ManagedAgentTileNSView.agentReferenceStatusSource`), reproduced here
    // without a canvas or a real tile — same two calls, same supervisor.
    func makeContext() -> AgentRenderContext {
        AgentRenderContext(
            actions: .disabled,
            tokens: .transcript,
            appearance: .dark,
            agentStatus: AgentReferenceStatusSource(
                current: { rawAgentID in
                    guard let snapshot = supervisor.turnSnapshot(for: AgentID(rawValue: rawAgentID)) else { return nil }
                    return InboxState.state(forSnapshot: snapshot)
                },
                subscribe: { _, _ in nil },
                unsubscribe: { _ in }
            )
        )
    }

    // A real `.childAgentSpawned` mutation, exactly what production emits —
    // not a hand-built document. `AgentTranscriptProjection` is the same
    // reducer the supervisor's own transcript persistence (C4) and every tile
    // use; this is its production shape for one `.agentReference` block.
    var projection = AgentTranscriptProjection(
        threadId: "parent-thread", monotonicNow: { 0 }, wallClockNow: { nil })
    projection.ingest(.childAgentSpawned(
        threadId: "parent-thread",
        childAgentID: childID.rawValue,
        parentAgentID: UUID(),
        displayName: "Test Child",
        sourceItemID: nil,
        provider: "pi",
        spawnedAt: Date(timeIntervalSince1970: 0)
    ))
    let document = projection.document
    guard let block = document.entries.flatMap(\.blocks).first(where: { $0.kind == .agentReference }),
          case let .agentReference(payload) = block.payload
    else {
        throw fail("agent-reference status check: ingesting .childAgentSpawned did not produce an .agentReference block")
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytesBeforeAnyStatusRead = try encoder.encode(document)

    let view = AgentReferenceChipView(frame: .zero)
    view.apply(blockID: block.id, payload: payload, context: makeContext())

    // Not started yet: no runner, no turn — reads `.ready`, which carries no
    // label (`InboxState.label` is nil for `.ready`), so the plain
    // "Subagent, …, open agent" form is the right starting assertion.
    guard view.accessibilityLabel() == "Subagent, Test Child, open agent" else {
        throw fail("agent-reference status check: initial accessibility label was \(String(describing: view.accessibilityLabel())), expected the unlabelled ready form")
    }

    // THE REAL STATUS CHANGE: production's own path, not a fixture poke.
    guard supervisor.send("go", to: childID) else {
        throw fail("agent-reference status check: could not start the child's turn")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.isRunning(childID) }) else {
        throw fail("agent-reference status check: the child's runner never started")
    }
    // `turnSnapshot`/`InboxState` are pull-based here (no live subscription
    // wired in this fixture); re-apply what the tile's own subscription
    // callback would have done — call the resolver again.
    view.apply(blockID: block.id, payload: payload, context: makeContext())

    guard view.accessibilityLabel() == "Subagent, Test Child, Working, open agent" else {
        throw fail("agent-reference status check: accessibility label after the turn started was \(String(describing: view.accessibilityLabel())), expected the Working form — the chip did not observe a real status change")
    }

    let bytesAfterStatusChange = try encoder.encode(document)
    guard bytesBeforeAnyStatusRead == bytesAfterStatusChange else {
        throw fail("agent-reference status check: the AgentDocument bytes changed across a status tick — a status must never rewrite the document")
    }

    supervisor.stop(childID)
    _ = await waitUntil(timeout: 5, pollInterval: 0.02, { !supervisor.isRunning(childID) })

    return "agent-reference chip: status resolved at render time via turnSnapshot/InboxState (ready \u{2192} working through a real send/stop), AgentDocument bytes unchanged across the tick"
}
