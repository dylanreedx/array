import ContinuumRevivedCore
import Foundation

// KB-01: host-owned board document operations. The transport only reaches this
// file through `WorkspaceAPIService.dispatch`; identity and grants are already
// bound to the managed agent before any board id is resolved.
extension WorkspaceAPIService {
    func boardQuery(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle,
        payload: [String: Any], runtime _: WorkspaceRuntime
    ) -> Reply {
        let request: BoardQueryRequest
        do {
            request = try Self.decoder.decode(BoardQueryRequest.self, from: JSONSerialization.data(withJSONObject: payload))
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "The board query could not be decoded: \(error.localizedDescription)"))
        }
        let handle = request.checkoutHandle ?? ownHandle
        guard case .allowed = WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .boardQuery, checkout: handle, requested: .preserveAll,
            grants: grants[agentId] ?? [], currentGeneration: revocationGeneration(for: agentId)) else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not query that project's boards."))
        }
        guard let projectId = projectID(for: handle, ownHandle: ownHandle, record: record),
              let boardRuntime = boardRuntimeProvider(projectId) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "That project's board runtime is unavailable."))
        }
        let entries = boardRuntime.boardIndexEntries()
        if let boardId = request.boardId {
            guard let board = boardRuntime.board(id: boardId),
                  entries.contains(where: { $0.id == boardId }) else {
                return .error(WorkspaceAPIError(code: .notFound, message: "No board with that id exists in this agent's project."))
            }
            if let cardId = request.cardId, board.card(cardId) == nil {
                return .error(WorkspaceAPIError(code: .notFound, message: "No task with that id exists on this board."))
            }
            let offset: Int
            switch BoardQueryPage.offset(from: request.cursor, boardId: boardId, revision: board.revision) {
            case .success(let value): offset = value
            case .failure(.cursorExpired):
                return .error(WorkspaceAPIError(code: .cursorExpired, message: "The board changed since this cursor was issued. Restart the query."))
            case .failure:
                return .error(WorkspaceAPIError(code: .invalidRequest, message: "The cursor is not one Array issued for this board."))
            }
            var ordered = board.orderedColumns.flatMap { board.orderedCards(in: $0.id) }
            if let cardId = request.cardId { ordered = ordered.filter { $0.id == cardId } }
            let start = min(offset, ordered.count)
            let limit = BoardQueryPage.clampedLimit(request.limit)
            var cards = Array(ordered[start..<min(start + limit, ordered.count)]).map {
                boardQueryCard($0, checkout: handle)
            }
            let tileId = entries.first(where: { $0.id == boardId })?.tileId
            func response(_ page: [BoardQueryCard]) -> BoardQueryResponse {
                let nextOffset = start + page.count
                return BoardQueryResponse(
                    checkoutHandle: handle, projectId: projectId,
                    board: BoardQueryDetail(
                        boardId: board.id, tileId: tileId, title: board.title, revision: board.revision,
                        columns: boardColumns(board), cards: page),
                    nextCursor: nextOffset < ordered.count
                        ? BoardQueryPage.cursor(boardId: board.id, revision: board.revision, offset: nextOffset) : nil,
                    truncated: nextOffset < ordered.count)
            }
            while cards.count > 1,
                  (try? Self.encoder.encode(response(cards)).count) ?? 0 > BoardQueryPage.encodedByteCeiling {
                cards.removeLast()
            }
            guard let object = Self.jsonObject(response(cards)) else {
                return .error(WorkspaceAPIError(code: .unsupported, message: "The board result could not be encoded."))
            }
            return .result(object)
        }

        let summaries = entries.compactMap { entry -> BoardQuerySummary? in
            guard let board = boardRuntime.board(id: entry.id) else { return nil }
            return BoardQuerySummary(
                boardId: board.id, tileId: entry.tileId, title: board.title,
                revision: board.revision, columns: boardColumns(board))
        }.sorted { lhs, rhs in
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.boardId.uuidString < rhs.boardId.uuidString : order == .orderedAscending
        }
        let offset: Int
        switch BoardQueryPage.offset(from: request.cursor, boardId: nil, revision: nil) {
        case .success(let value): offset = value
        case .failure: return .error(WorkspaceAPIError(code: .invalidRequest, message: "The cursor is not one Array issued for the board list."))
        }
        let start = min(offset, summaries.count)
        let limit = BoardQueryPage.clampedLimit(request.limit)
        var page = Array(summaries[start..<min(start + limit, summaries.count)])
        func response(_ items: [BoardQuerySummary]) -> BoardQueryResponse {
            let nextOffset = start + items.count
            return BoardQueryResponse(
                checkoutHandle: handle, projectId: projectId, boards: items,
                nextCursor: nextOffset < summaries.count
                    ? BoardQueryPage.cursor(boardId: nil, revision: nil, offset: nextOffset) : nil,
                truncated: nextOffset < summaries.count)
        }
        while page.count > 1,
              (try? Self.encoder.encode(response(page)).count) ?? 0 > BoardQueryPage.encodedByteCeiling {
            page.removeLast()
        }
        guard let object = Self.jsonObject(response(page)) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "The board list could not be encoded."))
        }
        return .result(object)
    }

    func boardApply(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle,
        requestId: String, payload: [String: Any], runtime _: WorkspaceRuntime,
        isCancelled: () -> Bool
    ) -> Reply {
        let request: BoardApplyRequest
        do {
            request = try Self.decoder.decode(BoardApplyRequest.self, from: JSONSerialization.data(withJSONObject: payload))
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "The board change could not be decoded: \(error.localizedDescription)"))
        }
        let handle = request.checkoutHandle ?? ownHandle
        guard case .allowed = WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .boardApply, checkout: handle, requested: .preserveAll,
            grants: grants[agentId] ?? [], currentGeneration: revocationGeneration(for: agentId)) else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not change that project's boards."))
        }
        guard !request.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.idempotencyKey.utf8.count <= 128 else {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "idempotencyKey is required and must be at most 128 bytes."))
        }
        let payloadHash = boardPayloadHash(request)
        if let cached = boardApplyIdempotency[agentId]?[request.idempotencyKey] {
            guard cached.payloadHash == payloadHash else {
                return .error(WorkspaceAPIError(code: .idempotencyConflict, message: "That idempotency key was already used for a different board change."))
            }
            guard let object = Self.jsonObject(cached.result) else {
                return .error(WorkspaceAPIError(code: .unsupported, message: "The remembered board result could not be encoded."))
            }
            return .result(object)
        }
        guard let projectId = projectID(for: handle, ownHandle: ownHandle, record: record),
              let boardRuntime = boardRuntimeProvider(projectId),
              let board = boardRuntime.board(id: request.boardId),
              boardRuntime.boardIndexEntries().contains(where: { $0.id == request.boardId }) else {
            return .error(WorkspaceAPIError(code: .notFound, message: "No board with that id exists in this agent's project."))
        }
        let stale = request.expectedRevision != board.revision
        let canRebase = (request.op == .create || request.op == .move)
            && (request.afterCardId != nil || request.beforeCardId != nil)
        guard !stale || canRebase else {
            return .error(WorkspaceAPIError(code: .revisionConflict, message: "expectedRevision \(request.expectedRevision) does not match board revision \(board.revision). Re-query before writing."))
        }

        let cardId = request.op == .create ? UUID() : request.cardId
        guard let cardId else {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "\(request.op.rawValue) requires cardId."))
        }
        let command: BoardCommand
        do {
            switch request.op {
            case .create:
                guard request.cardId == nil else { throw BoardRequestFailure("Array creates cardId for create operations; omit cardId.") }
                guard let columnId = request.columnId else { throw BoardRequestFailure("create requires columnId.") }
                let title = try validatedBoardTitle(request.title, required: true)
                let links = try resolveBoardLinks(request.links ?? [], checkout: handle, projectId: projectId)
                try validateBoardAssignee(request.assigneeAgentId, projectId: projectId)
                command = .createTask(
                    id: cardId, columnId: columnId, title: title!, body: try validatedBoardBody(request.body ?? ""),
                    links: links, assignee: request.assigneeAgentId,
                    after: request.afterCardId, before: request.beforeCardId)
            case .edit:
                guard request.columnId == nil, request.assigneeAgentId == nil,
                      request.afterCardId == nil, request.beforeCardId == nil else {
                    throw BoardRequestFailure("edit accepts only cardId, title, body, and links.")
                }
                guard request.title != nil || request.body != nil || request.links != nil else {
                    throw BoardRequestFailure("edit requires at least one of title, body, or links.")
                }
                command = .editTaskFields(
                    id: cardId,
                    title: try validatedBoardTitle(request.title, required: false),
                    body: try request.body.map(validatedBoardBody),
                    links: try request.links.map { try resolveBoardLinks($0, checkout: handle, projectId: projectId) })
            case .move:
                guard request.title == nil, request.body == nil, request.links == nil,
                      request.assigneeAgentId == nil else {
                    throw BoardRequestFailure("move accepts only cardId, columnId, and neighbour anchors.")
                }
                guard let columnId = request.columnId else { throw BoardRequestFailure("move requires columnId.") }
                command = .moveCard(id: cardId, toColumn: columnId, after: request.afterCardId, before: request.beforeCardId)
            case .assign:
                guard request.columnId == nil, request.title == nil, request.body == nil,
                      request.links == nil, request.afterCardId == nil, request.beforeCardId == nil else {
                    throw BoardRequestFailure("assign accepts only cardId and assigneeAgentId.")
                }
                guard let assignee = request.assigneeAgentId else { throw BoardRequestFailure("assign requires assigneeAgentId.") }
                try validateBoardAssignee(assignee, projectId: projectId)
                command = .assignCard(id: cardId, to: assignee)
            case .unassign:
                guard request.columnId == nil, request.title == nil, request.body == nil,
                      request.links == nil, request.assigneeAgentId == nil,
                      request.afterCardId == nil, request.beforeCardId == nil else {
                    throw BoardRequestFailure("unassign accepts only cardId.")
                }
                command = .assignCard(id: cardId, to: nil)
            case .delete:
                guard request.columnId == nil, request.title == nil, request.body == nil,
                      request.links == nil, request.assigneeAgentId == nil,
                      request.afterCardId == nil, request.beforeCardId == nil else {
                    throw BoardRequestFailure("delete accepts only cardId.")
                }
                command = .deleteCard(id: cardId)
            }
        } catch let failure as BoardRequestFailure {
            return .error(WorkspaceAPIError(code: failure.code, message: failure.message))
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: error.localizedDescription))
        }

        _beforeCommitHook?()
        if isCancelled() {
            remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .boardApply, outcome: "cancelledBeforeEffect"))
            return .cancelled(result: nil)
        }
        guard supervisor.records[agentId]?.workspaceToolsEnabled == true else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "Workspace tools were revoked before the board changed."))
        }
        // Strict writes recheck after the test/user interleave seam. Rebasable
        // writes intentionally let BoardEngine validate their live anchors.
        guard let current = boardRuntime.board(id: request.boardId) else {
            return .error(WorkspaceAPIError(code: .notFound, message: "The board was removed before the change was applied."))
        }
        let nowStale = request.expectedRevision != current.revision
        guard !nowStale || canRebase else {
            return .error(WorkspaceAPIError(code: .revisionConflict, message: "The board changed before this operation could be applied. Re-query before writing."))
        }
        let outcome = boardRuntime.apply(command, to: request.boardId)
        let resultOutcome: BoardApplyResult.Outcome
        switch outcome {
        case .applied: resultOutcome = (stale || nowStale) ? .rebased : .applied
        case .rebased: resultOutcome = .rebased
        case .rejectedCardHeldByPointer:
            return .error(WorkspaceAPIError(code: .busy, message: "The user is currently dragging that task. Re-query after the gesture ends."))
        case .persistenceFailed:
            remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .boardApply, outcome: "durabilityFailed"))
            return .error(WorkspaceAPIError(code: .durabilityFailed, message: "The board could not be saved, so the change was rolled back."))
        case .rejected(let error):
            return .error(boardError(error))
        }
        guard let updated = boardRuntime.board(id: request.boardId) else {
            return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "The board committed but its result could not be read."))
        }
        let result = BoardApplyResult(
            operationId: requestId, op: request.op, boardId: request.boardId, cardId: cardId,
            outcome: resultOutcome, undoRegistered: true, revision: updated.revision,
            card: updated.card(cardId).map { boardQueryCard($0, checkout: handle) })
        cacheBoardApply(agentId: agentId, key: request.idempotencyKey, hash: payloadHash, result: result)
        remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .boardApply, outcome: "committed"))
        if isCancelled() { return .cancelled(result: Self.jsonObject(result)) }
        guard let object = Self.jsonObject(result) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "The board result could not be encoded."))
        }
        return .result(object)
    }

    private func projectID(for handle: CheckoutHandle, ownHandle: CheckoutHandle, record: AgentRecord) -> UUID? {
        if handle == ownHandle { return record.projectId }
        return knownCheckouts()[handle]?.projectId
    }

    private func boardColumns(_ board: Board) -> [BoardQueryColumn] {
        board.orderedColumns.map { BoardQueryColumn(columnId: $0.id, name: $0.name, cardCount: board.orderedCards(in: $0.id).count) }
    }

    private func boardQueryCard(_ card: BoardCard, checkout: CheckoutHandle) -> BoardQueryCard {
        BoardQueryCard(
            cardId: card.id, columnId: card.columnId, title: card.title, body: card.body,
            links: card.links.compactMap { boardAPILink($0, fallbackCheckout: checkout) },
            attachments: card.attachments, assigneeAgentId: card.assignee,
            createdAt: card.createdAt, updatedAt: card.updatedAt)
    }

    private func boardAPILink(_ link: CardLink, fallbackCheckout: CheckoutHandle) -> BoardAPILink? {
        switch link {
        case .agent(let id): return BoardAPILink(kind: .agent, agentId: id)
        case .tile(let id): return BoardAPILink(kind: .tile, tileId: id)
        case .url(let value): return BoardAPILink(kind: .url, url: value)
        case .document(let location):
            guard let relativePath = location.relativePath else { return nil }
            let handle = location.checkoutRootPath.map { CheckoutHandle.derive(canonicalRoot: CheckoutHandle.canonicalRoot($0)) } ?? fallbackCheckout
            return BoardAPILink(kind: .document, artifactHandle: ArtifactHandle(checkoutHandle: handle, relativePath: relativePath).rawValue)
        }
    }

    private func resolveBoardLinks(_ links: [BoardAPILink], checkout: CheckoutHandle, projectId: UUID) throws -> [CardLink] {
        guard links.count <= 32 else { throw BoardRequestFailure("A task may contain at most 32 links.") }
        return try links.map { link in
            switch link.kind {
            case .document:
                guard link.agentId == nil, link.tileId == nil, link.url == nil,
                      let raw = link.artifactHandle, let artifact = ArtifactHandle(rawValue: raw),
                      artifact.checkoutHandle == checkout,
                      let known = knownCheckouts()[checkout] else {
                    throw BoardRequestFailure("A document link needs an artifactHandle from this checkout.")
                }
                let file = known.root.appendingPathComponent(artifact.relativePath)
                guard DocumentLocationResolver.contains(file, in: known.root) else {
                    throw BoardRequestFailure("The document link leaves the authorized checkout.")
                }
                return .document(DocumentLocationResolver.resolve(
                    fileURL: file,
                    explicitRoot: DocumentLocationRoot(rootURL: known.root, projectId: projectId)))
            case .agent:
                guard link.artifactHandle == nil, link.tileId == nil, link.url == nil,
                      let id = link.agentId else {
                    throw BoardRequestFailure("An agent link must name an agent in this project.")
                }
                guard let target = supervisor.records[id] else {
                    throw BoardRequestFailure("No agent with that id exists.", code: .notFound)
                }
                guard target.projectId == projectId else {
                    throw BoardRequestFailure("An agent link must name an agent in this project.")
                }
                return .agent(id)
            case .tile:
                guard link.artifactHandle == nil, link.agentId == nil, link.url == nil,
                      let id = link.tileId else {
                    throw BoardRequestFailure("A tile link must name a tile in this project.")
                }
                guard let root = knownCheckouts()[checkout]?.root,
                      (try? ProjectStore(projectRoot: root).tryLoadCanvas()?.tiles.contains(where: { $0.id == id })) == true else {
                    throw BoardRequestFailure("No tile with that id exists in this project.", code: .notFound)
                }
                return .tile(id)
            case .url:
                guard link.artifactHandle == nil, link.agentId == nil, link.tileId == nil,
                      let raw = link.url, raw.utf8.count <= 4096,
                      let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    throw BoardRequestFailure("A URL link must be an http or https URL no longer than 4096 bytes.")
                }
                return .url(raw)
            }
        }
    }

    private func validateBoardAssignee(_ id: AgentID?, projectId: UUID) throws {
        guard let id else { return }
        guard let target = supervisor.records[id] else {
            throw BoardRequestFailure("No agent with that id exists.", code: .notFound)
        }
        guard target.projectId == projectId, target.archivedAt == nil,
              target.capabilities.locallyManaged else {
            throw BoardRequestFailure("The assignee must be an available managed agent in this project.")
        }
    }

    private func validatedBoardTitle(_ title: String?, required: Bool) throws -> String? {
        guard let title else {
            if required { throw BoardRequestFailure("create requires title.") }
            return nil
        }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 500 else {
            throw BoardRequestFailure("A task title must be non-empty and at most 500 bytes.")
        }
        return value
    }

    private func validatedBoardBody(_ body: String) throws -> String {
        guard body.utf8.count <= 65_536 else { throw BoardRequestFailure("A task body may be at most 64 KB.") }
        return body
    }

    private func boardError(_ error: BoardCommandError) -> WorkspaceAPIError {
        switch error {
        case .unknownCard, .unknownColumn:
            return WorkspaceAPIError(code: .notFound, message: error.description)
        case .contentConflict:
            return WorkspaceAPIError(code: .revisionConflict, message: error.description)
        case .duplicateCard, .duplicateColumn, .anchorsUnavailable, .lastColumn, .invalidReassignment:
            return WorkspaceAPIError(code: .invalidRequest, message: error.description)
        }
    }

    private func boardPayloadHash(_ request: BoardApplyRequest) -> String {
        var normalized = request
        normalized.idempotencyKey = ""
        return (try? Self.encoder.encode(normalized)).map { String(decoding: $0, as: UTF8.self) } ?? UUID().uuidString
    }

    private func cacheBoardApply(agentId: AgentID, key: String, hash: String, result: BoardApplyResult) {
        boardApplyIdempotency[agentId, default: [:]][key] = CachedBoardApply(payloadHash: hash, result: result)
        boardApplyIdempotencyOrder[agentId, default: []].append(key)
        while (boardApplyIdempotencyOrder[agentId]?.count ?? 0) > Self.idempotencyCapacity {
            let evicted = boardApplyIdempotencyOrder[agentId]!.removeFirst()
            boardApplyIdempotency[agentId]?[evicted] = nil
        }
    }
}

private struct BoardRequestFailure: Error {
    let message: String
    let code: WorkspaceAPIError.Code
    init(_ message: String, code: WorkspaceAPIError.Code = .invalidRequest) {
        self.message = message
        self.code = code
    }
}

private extension WorkspaceAPIService {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
