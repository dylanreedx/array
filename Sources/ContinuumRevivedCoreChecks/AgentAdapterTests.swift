import ContinuumRevivedCore
import Foundation

func runAgentAdapterTests() {
    let threadId = "thread-main"
    let otherThreadId = "thread-other"

    let events: [AgentRuntimeEvent] = [
        .sessionStateChanged(.starting),
        .sessionStateChanged(.running),
        .turnStarted(threadId: threadId, turnId: "turn-1"),
        .itemStarted(threadId: threadId, itemId: "item-1", kind: .commandExecution, title: "run build"),
        .contentDelta(threadId: threadId, turnId: "turn-1", streamKind: .assistant, delta: "SECRET_BODY"),
        .requestOpened(threadId: otherThreadId, requestId: "other-request", kind: .commandExecutionApproval),
        .requestOpened(threadId: threadId, requestId: "request-1", kind: .commandExecutionApproval),
        .userInputRequested(threadId: threadId, requestId: "input-1", questions: [
            UserInputQuestion(key: "confirm", prompt: "Proceed?")
        ]),
        .userInputResolved(threadId: threadId, requestId: "input-1"),
        .requestResolved(threadId: threadId, requestId: "request-1", decision: "approve"),
        .itemCompleted(threadId: threadId, itemId: "item-1", kind: .commandExecution, status: .completed),
        .turnCompleted(threadId: threadId, turnId: "turn-1", outcome: .completed, errorMessage: nil),
        .tokenUsageUpdated(threadId: threadId, snapshot: TokenUsageSnapshot(inputTokens: 12, outputTokens: 34, totalCostUsd: 0.05)),
        .runtimeError(threadId: otherThreadId, message: "other thread failed")
    ]

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let decodedEvents = try! events.map { event in
        try decoder.decode(AgentRuntimeEvent.self, from: encoder.encode(event))
    }
    expect(decodedEvents == events, "AgentRuntimeEvent must Codable round-trip every canonical case")
    let eventTypes = try! events.map { event -> String in
        let data = try encoder.encode(event)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return object["type"] as! String
    }
    expect(eventTypes == [
        "sessionStateChanged",
        "sessionStateChanged",
        "turnStarted",
        "itemStarted",
        "contentDelta",
        "requestOpened",
        "requestOpened",
        "userInputRequested",
        "userInputResolved",
        "requestResolved",
        "itemCompleted",
        "turnCompleted",
        "tokenUsageUpdated",
        "runtimeError"
    ], "AgentRuntimeEvent JSON type discriminators must stay stable")

    let differentThreadSignals = deriveStatusSignals(
        from: [.requestOpened(threadId: otherThreadId, requestId: "other-request", kind: .commandExecutionApproval)],
        threadId: threadId,
        engineStatus: .idle
    )
    expect(!differentThreadSignals.hasPendingApproval, "deriveStatusSignals must ignore approvals from other threads")

    let pendingApprovalSignals = deriveStatusSignals(
        from: [
            .sessionStateChanged(.running),
            .requestOpened(threadId: threadId, requestId: "request-1", kind: .commandExecutionApproval)
        ],
        threadId: threadId,
        engineStatus: .idle
    )
    expect(pendingApprovalSignals.hasPendingApproval, "requestOpened must set hasPendingApproval")
    expect(pendingApprovalSignals.isRunning, "running session with pending approval remains running")
    expect(deriveAgentStatus(signals: pendingApprovalSignals) == .needsAttention, "pending approval must win over running status")

    let resolvedSignals = deriveStatusSignals(
        from: [
            .sessionStateChanged(.running),
            .requestOpened(threadId: threadId, requestId: "request-1", kind: .commandExecutionApproval),
            .requestResolved(threadId: threadId, requestId: "request-1", decision: "approve")
        ],
        threadId: threadId,
        engineStatus: .idle
    )
    expect(!resolvedSignals.hasPendingApproval, "requestResolved must clear matching pending approval")
    expect(deriveAgentStatus(signals: resolvedSignals) == .working, "resolved approval returns to working while running")

    let pendingInputSignals = deriveStatusSignals(
        from: [.userInputRequested(threadId: threadId, requestId: "input-1", questions: [])],
        threadId: threadId,
        engineStatus: .idle
    )
    expect(pendingInputSignals.hasPendingUserInput, "userInputRequested must set hasPendingUserInput")
    expect(deriveAgentStatus(signals: pendingInputSignals) == .needsAttention, "pending user input must derive needsAttention")

    let waitingSignals = deriveStatusSignals(
        from: [.sessionStateChanged(.waiting)],
        threadId: threadId,
        engineStatus: .idle
    )
    expect(waitingSignals.isRunning, "sessionStateChanged(.waiting) must map to running/live")
    expect(!waitingSignals.hookBreadcrumbPresent, "managed adapter projection never sets hookBreadcrumbPresent")

    let completedSignals = deriveStatusSignals(
        from: [
            .sessionStateChanged(.ready),
            .turnCompleted(threadId: threadId, turnId: "turn-1", outcome: .completed, errorMessage: nil)
        ],
        threadId: threadId,
        engineStatus: .idle
    )
    expect(completedSignals.isCompleted, "completed turn must set isCompleted")
    expect(deriveAgentStatus(signals: completedSignals) == .done, "completed turn must derive done")

    let failedSignals = deriveStatusSignals(
        from: [.turnCompleted(threadId: threadId, turnId: "turn-1", outcome: .failed, errorMessage: "failure")],
        threadId: threadId,
        engineStatus: .idle
    )
    expect(failedSignals.isError, "failed turn must set isError")

    let errorSignals = deriveStatusSignals(
        from: [.sessionStateChanged(.error)],
        threadId: threadId,
        engineStatus: .idle
    )
    expect(errorSignals.isError, "error session state must set isError")

    struct ProbeAdapter: AgentAdapter {
        let events: AsyncStream<AgentRuntimeEvent> = AsyncStream { continuation in
            continuation.finish()
        }
        var providerKind: AgentKind { .managed }
        func startSession(_ input: AgentSessionStartInput) async throws -> AgentSession {
            AgentSession(threadId: input.resumeThreadId ?? "thread-main", providerSessionId: "provider-1")
        }
        func sendTurn(_ input: AgentSendTurnInput) async throws -> AgentTurnStartResult {
            AgentTurnStartResult(turnId: "turn-1")
        }
        func interruptTurn(threadId: String, turnId: String?) async throws {}
        func stopSession(threadId: String) async throws {}
        func respondToRequest(threadId: String, requestId: String, decision: ApprovalDecision) async throws {}
        func respondToUserInput(threadId: String, requestId: String, answers: UserInputAnswers) async throws {}
        func hasSession(threadId: String) async -> Bool { threadId == "thread-main" }
    }
    let adapter = ProbeAdapter()
    expect(adapter.providerKind == .managed, "AgentAdapter providerKind must use closed AgentKind.managed")
}
