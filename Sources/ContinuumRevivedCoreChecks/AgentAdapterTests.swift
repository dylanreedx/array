import ContinuumRevivedAgentUI
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

    let resolvedInputSignals = deriveStatusSignals(
        from: [
            .sessionStateChanged(.running),
            .userInputRequested(threadId: threadId, requestId: "input-1", questions: [
                UserInputQuestion(key: "confirm", prompt: "Proceed?")
            ]),
            .userInputResolved(threadId: threadId, requestId: "input-1")
        ],
        threadId: threadId,
        engineStatus: .idle
    )
    expect(!resolvedInputSignals.hasPendingUserInput, "userInputResolved must clear matching pending user input")
    expect(deriveAgentStatus(signals: resolvedInputSignals) == .working, "resolved user input returns to working while running")

    let inputRequest = AgentUserInputRequest(
        requestId: "input-2",
        tileId: UUID(uuidString: "73000000-0000-4000-8000-000000000073")!,
        question: String(repeating: "a", count: 170) + "\nsecret"
    )
    expect(inputRequest.question.count == 160, "AgentUserInputRequest must cap question text at 160 chars")
    expect(!inputRequest.question.contains("\n"), "AgentUserInputRequest must sanitize newlines at ingestion")

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

    runManagedSessionWithApprovalFixtureCheck()
}

private func runManagedSessionWithApprovalFixtureCheck() {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("managed-session-with-approval.jsonl", isDirectory: false)

    guard let fixtureText = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
        fputs("FAIL: AgentAdapter integration fixture missing at \(fixtureURL.path)\n", stderr)
        Foundation.exit(1)
    }

    let decoder = JSONDecoder()
    let lines = fixtureText
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
    let events = lines.enumerated().map { offset, line -> AgentRuntimeEvent in
        guard let data = line.data(using: .utf8) else {
            fputs("FAIL: AgentAdapter fixture line \(offset + 1) is not UTF-8\n", stderr)
            Foundation.exit(1)
        }
        do {
            return try decoder.decode(AgentRuntimeEvent.self, from: data)
        } catch {
            fputs("FAIL: AgentAdapter fixture line \(offset + 1) failed Codable decode: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    expect(events.count == 12, "AgentAdapter fixture must contain the committed 12-event managed-session sequence, got \(events.count)")

    let threadId = "thread-main"
    var accumulated: [AgentRuntimeEvent] = []
    var statuses: [AgentStatus] = []
    for event in events {
        accumulated.append(event)
        let signals = deriveStatusSignals(from: accumulated, threadId: threadId, engineStatus: .idle)
        statuses.append(deriveAgentStatus(signals: signals))
    }

    let statusPhases = statuses.reduce(into: [AgentStatus]()) { phases, status in
        if phases.last != status {
            phases.append(status)
        }
    }
    expect(
        statusPhases == [.configuring, .working, .needsAttention, .working, .done],
        "AgentAdapter fixture status phases must be configuring -> working -> needsAttention -> working -> done, got \(statusPhases)"
    )

    let openedIndex = events.firstIndex {
        if case .requestOpened("thread-main", "request-1", .commandExecutionApproval) = $0 {
            return true
        }
        return false
    }
    expect(openedIndex != nil, "AgentAdapter fixture must include requestOpened for request-1")
    if let openedIndex {
        expect(statuses[openedIndex] == .needsAttention, "AgentAdapter fixture requestOpened must derive needsAttention")
    }

    let resolvedIndex = events.firstIndex {
        if case .requestResolved("thread-main", "request-1", "approve") = $0 {
            return true
        }
        return false
    }
    expect(resolvedIndex != nil, "AgentAdapter fixture must include requestResolved approval for request-1")
    if let resolvedIndex {
        expect(statuses[resolvedIndex] == .working, "AgentAdapter fixture requestResolved must return to working")
    }

    expect(statuses.last == .done, "AgentAdapter fixture final ready-after-completed boundary must derive done")
}
