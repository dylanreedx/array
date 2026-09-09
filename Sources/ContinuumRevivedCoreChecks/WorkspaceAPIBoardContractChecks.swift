import ContinuumRevivedCore
import Foundation

func runWorkspaceAPIBoardContractChecks() {
    let boardID = UUID()
    let cardID = UUID()
    let agentID = AgentID(rawValue: UUID())
    let handle = CheckoutHandle.derive(canonicalRoot: "/tmp/board-contract")

    expect(WorkspaceAPIOp(rawValue: "board.query") == .boardQuery
           && WorkspaceAPIOp(rawValue: "board.apply") == .boardApply,
           "KB-01 API: board operations keep their wire names")
    expect(WorkspaceAPIOp.sessionPresetOperations.contains(.boardQuery)
           && WorkspaceAPIOp.sessionPresetOperations.contains(.boardApply),
           "KB-01 API: own-checkout sessions grant both board operations")
    let principal = AgentID(rawValue: UUID())
    let own = CheckoutHandle.derive(canonicalRoot: "/tmp/board-own")
    let foreign = CheckoutHandle.derive(canonicalRoot: "/tmp/board-foreign")
    let preset = WorkspaceToolGrant.phase1Preset(agentId: principal, checkout: own, generation: 0)
    expect(WorkspaceToolGrantEvaluator.evaluate(
        agentId: principal, op: .boardApply, checkout: foreign, requested: .preserveAll,
        grants: [preset], currentGeneration: 0) == .scopeApprovalRequired(missing: foreign),
           "KB-01 API: another checkout still requires the existing scoped grant")
    expect(WorkspaceAPIError.Code.busy.rawValue == "busy"
           && WorkspaceAPIError.Code.durabilityFailed.rawValue == "durability_failed",
           "KB-01 API: board failures keep stable wire codes")

    let cursor = BoardQueryPage.cursor(boardId: boardID, revision: 7, offset: 3)
    expect(BoardQueryPage.offset(from: cursor, boardId: boardID, revision: 7) == .success(3),
           "KB-01 API: detailed cursors round-trip board, revision and offset")
    expect(BoardQueryPage.offset(from: cursor, boardId: boardID, revision: 8) == .failure(.cursorExpired),
           "KB-01 API: a board edit expires its detailed cursor")
    expect(BoardQueryPage.offset(from: cursor, boardId: UUID(), revision: 7) == .failure(.invalidRequest),
           "KB-01 API: a cursor cannot cross board identities")

    let request = BoardApplyRequest(
        op: .create, boardId: boardID, expectedRevision: 7, idempotencyKey: "qa-1",
        checkoutHandle: handle, columnId: UUID(), title: "QA note", body: "Steps",
        links: [BoardAPILink(kind: .agent, agentId: agentID)], assigneeAgentId: agentID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let decoded = try! JSONDecoder().decode(BoardApplyRequest.self, from: encoder.encode(request))
    expect(decoded == request, "KB-01 API: board apply request is Codable with typed links")

    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let card = BoardQueryCard(
        cardId: cardID, columnId: request.columnId!, title: "QA note", body: "Steps",
        links: request.links!, attachments: [], assigneeAgentId: agentID,
        createdAt: now, updatedAt: now)
    let result = BoardApplyResult(
        operationId: "op-1", op: .create, boardId: boardID, cardId: cardID,
        outcome: .applied, undoRegistered: true, revision: 8, card: card)
    expect(try! JSONDecoder().decode(BoardApplyResult.self, from: encoder.encode(result)) == result,
           "KB-01 API: board apply result round-trips operation, durability, revision and card")
    print("WorkspaceAPIBoardContractChecks passed")
}
