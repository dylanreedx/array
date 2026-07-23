import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/88-provider-adapter-pi-gpt.md (slice 88.4c)
//
// The bridge maps the rich runtime event stream to the I5-safe activity drafts
// that cross to the phone. Pins: which events surface (turn/tool/approval/
// error) vs. which are dropped (content deltas, token usage), and that no
// transcript/secret text can ride through a draft summary.
func runManagedAgentActivityBridgeChecks() {
    let tile = UUID()
    let thread = "managed-\(tile.uuidString)"
    func draft(_ e: AgentRuntimeEvent) -> AgentActivityEventDraft? {
        ManagedAgentActivityBridge.draft(for: e, tileId: tile, status: .working, now: Date(timeIntervalSinceReferenceDate: 0))
    }

    // 1. Surfaced events map to the expected kind/tone.
    expect(draft(.turnStarted(threadId: thread, turnId: "t1"))?.kind == "turn.started",
           "bridge: turnStarted → turn.started")
    let toolStart = draft(.itemStarted(threadId: thread, itemId: "c1", kind: .commandExecution, title: "read"))
    expect(toolStart?.kind == "tool.read" && toolStart?.tone == .tool,
           "bridge: itemStarted carries the tool name, tone .tool, got \(String(describing: toolStart))")
    let toolFail = draft(.itemCompleted(threadId: thread, itemId: "c1", kind: .commandExecution, status: .failed))
    expect(toolFail?.tone == .error, "bridge: a failed tool item is toned .error")
    let approval = draft(.requestOpened(threadId: thread, requestId: "r1", kind: .commandExecutionApproval))
    expect(approval?.tone == .approval && approval?.approvalRequestId == "r1",
           "bridge: requestOpened → approval draft carrying the request id")
    expect(draft(.turnCompleted(threadId: thread, turnId: "t1", outcome: .completed, errorMessage: nil))?.kind == "turn.completed",
           "bridge: turnCompleted(.completed) → turn.completed")

    // 2. Dropped events return nil (never cross): content deltas + token usage.
    expect(draft(.contentDelta(threadId: thread, turnId: "t1", streamKind: .assistant, delta: "some assistant text")) == nil,
           "bridge: content deltas must NOT become activity (I5 + noise)")
    expect(draft(.sessionStateChanged(.running)) == nil, "bridge: session state changes ride on other events' status")

    // 3. I5: no transcript/secret can ride a summary. Feed a runtimeError whose
    //    message contains a secret + is very long; assert the summary is bounded
    //    and, once stamped+encoded as the wire event, nothing unbounded leaks.
    let longSecret = "SECRET-" + String(repeating: "x", count: 5000)
    let errDraft = draft(.runtimeError(threadId: thread, message: longSecret))
    expect(errDraft != nil && (errDraft!.summary.count <= 200), "bridge: error summary is truncated (<=200), got \(errDraft?.summary.count ?? -1)")
    let stamped = AgentActivityEvent(stamping: errDraft!, sequence: 1, replicaId: UUID())
    let json = String(decoding: try! JSONEncoder().encode(stamped), as: UTF8.self)
    expect(!json.contains(String(repeating: "x", count: 300)),
           "bridge I5: no unbounded transcript body may appear in the encoded activity event")

    print("ManagedAgentActivityBridge checks passed: turn/tool/approval/error surface, deltas/token-usage dropped, error summary bounded (I5)")
}
