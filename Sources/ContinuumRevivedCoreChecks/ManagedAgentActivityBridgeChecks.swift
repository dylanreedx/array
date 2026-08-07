import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/88-provider-adapter-pi-gpt.md (slice 88.4c)
//
// The bridge maps the rich runtime event stream to the I5-safe activity drafts
// that cross to the phone. Pins: which events surface (turn/tool/approval/
// error) vs. which are dropped (content deltas, token usage), and that no
// transcript/secret text can ride through a draft summary.
func runManagedAgentActivityBridgeChecks() {
    let agent = UUID()
    let tile = UUID()
    let thread = "managed-\(tile.uuidString)"
    func draft(_ e: AgentRuntimeEvent) -> AgentActivityEventDraft? {
        ManagedAgentActivityBridge.draft(for: e, agentId: agent, tileId: tile, status: .working, now: Date(timeIntervalSinceReferenceDate: 0))
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

    // 2. Dropped events return nil (never cross): content deltas + token/context telemetry.
    expect(draft(.contentDelta(threadId: thread, turnId: "t1", streamKind: .assistant, delta: "some assistant text")) == nil,
           "bridge: content deltas must NOT become activity (I5 + noise)")
    expect(draft(.tokenUsageUpdated(threadId: thread, snapshot: TokenUsageSnapshot(inputTokens: 1, outputTokens: 2, totalCostUsd: nil))) == nil,
           "bridge: token usage must NOT become synced activity (noise)")
    expect(draft(.contextWindowUpdated(threadId: thread, snapshot: AgentContextWindowSnapshot(observedAt: Date(timeIntervalSinceReferenceDate: 0), source: .piMessageUsage, freshness: .live))) == nil,
           "bridge: context telemetry must NOT become synced activity (privacy/noise)")
    expect(draft(.sessionStateChanged(.running)) == nil, "bridge: session state changes ride on other events' status")

    // 3. I5: raw error text must NEVER cross — it carries provider stderr
    //    (paths, secrets). The synced summary is generic; the secret is absent
    //    entirely, not merely truncated.
    let secretErr = "pi failed: /Users/dylan/secret/path SECRET-TOKEN-42 " + String(repeating: "x", count: 5000)
    let errDraft = draft(.runtimeError(threadId: thread, message: secretErr))
    expect(errDraft?.summary == "Runtime error", "bridge I5: runtimeError summary is generic, got \(String(describing: errDraft?.summary))")
    let failDraft = draft(.turnCompleted(threadId: thread, turnId: "t1", outcome: .failed, errorMessage: secretErr))
    expect(failDraft?.summary == "Turn failed", "bridge I5: failed-turn summary is generic, got \(String(describing: failDraft?.summary))")
    for d in [errDraft, failDraft] {
        let json = String(decoding: try! JSONEncoder().encode(AgentActivityEvent(stamping: d!, sequence: 1, replicaId: UUID())), as: UTF8.self)
        expect(!json.contains("SECRET-TOKEN-42") && !json.contains("/Users/dylan"),
               "bridge I5: no secret/path from error text may appear in the wire event")
    }

    // 4. I5 defense-in-depth: a tool title carrying a path/args collapses to a
    //    generic token — no path component or secret word survives.
    let pathTitle = draft(.itemStarted(threadId: thread, itemId: "c1", kind: .commandExecution, title: "read /Users/dylan/SECRET.txt --flag"))!
    let blob = pathTitle.kind + " " + pathTitle.summary
    expect(pathTitle.kind == "tool.tool", "bridge I5: path-like tool title collapses to generic, got kind=\(pathTitle.kind)")
    expect(!blob.contains("SECRET") && !blob.contains("Users") && !blob.contains("/"),
           "bridge I5: no path component / secret survives a path-like tool title — got \(blob)")
    // A legitimate bare tool name is preserved.
    let bare = draft(.itemStarted(threadId: thread, itemId: "c2", kind: .webSearch, title: "web_search"))!
    expect(bare.kind == "tool.web_search", "bridge: a bare tool name is preserved, got \(bare.kind)")

    print("ManagedAgentActivityBridge checks passed: surface set correct, deltas/token-usage dropped, error text NEVER crosses (generic), tool title sanitized (I5)")
}
