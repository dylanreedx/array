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
            if request.commentId != nil && ![BoardApplyRequest.Op.editComment, .deleteComment].contains(request.op) { throw BoardRequestFailure("commentId is only valid for editComment/deleteComment.") }
            switch request.op {
            case .comment, .editComment, .deleteComment:
                guard request.columnId == nil, request.title == nil, request.links == nil,
                      request.assigneeAgentId == nil, request.afterCardId == nil, request.beforeCardId == nil else {
                    throw BoardRequestFailure("Comment operations accept cardId, body and commentId only.")
                }
                let author = agentId.rawValue.uuidString.lowercased()
                if request.op == .comment {
                    guard request.commentId == nil else { throw BoardRequestFailure("Array creates commentId.") }
                    let body = try validatedBoardBody(request.body ?? "")
                    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 8192 else { throw BoardRequestFailure("Comment body must be 1–8192 bytes.") }
                    var comment = BoardComment(authorID: author, authorName: supervisor.records[agentId]?.humanDisplayName ?? "Agent", createdAt: Date(), body: body)
                    if let record = supervisor.records[agentId] {
                        let identity = boardCommentIdentity(record, dark: true)
                        comment.authorColour = identity["colour"] as? String
                        comment.authorCharacter = identity["character"] as? String
                    }
                    command = .addComment(cardID: cardId, comment: comment)
                } else {
                    guard let commentID = request.commentId else { throw BoardRequestFailure("commentId is required.") }
                    guard let existing = board.card(cardId)?.comments.first(where: { $0.id == commentID }) else { throw BoardRequestFailure("No comment with that id exists on this card.", code: .notFound) }
                    guard existing.authorID == author else { throw BoardRequestFailure("You may change only your own comments.", code: .permissionDenied) }
                    if request.op == .deleteComment {
                        guard request.body == nil else { throw BoardRequestFailure("deleteComment does not accept body.") }
                        command = .deleteComment(cardID: cardId, commentID: commentID, authorID: author)
                    } else {
                        let body = try validatedBoardBody(request.body ?? "")
                        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 8192 else { throw BoardRequestFailure("Comment body must be 1–8192 bytes.") }
                        command = .editComment(cardID: cardId, commentID: commentID, authorID: author, body: body)
                    }
                }
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
                command = .setCardAssignees(id: cardId, agents: (board.card(cardId)?.assignees ?? []) + [assignee])
            case .unassign:
                guard request.columnId == nil, request.title == nil, request.body == nil,
                      request.links == nil,
                      request.afterCardId == nil, request.beforeCardId == nil else {
                    throw BoardRequestFailure("unassign accepts cardId and optional assigneeAgentId.")
                }
                command = .setCardAssignees(id: cardId, agents: request.assigneeAgentId.map { removed in (board.card(cardId)?.assignees ?? []).filter { $0 != removed } } ?? [])
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
        // A delete leaves no card to read the title from afterwards.
        let titleBeforeChange = current.card(cardId)?.title
        let outcome = boardRuntime.apply(command, to: request.boardId, actingAgent: agentId)
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
        let updatedCard = updated.card(cardId)
        let result = BoardApplyResult(
            operationId: requestId, op: request.op, boardId: request.boardId, cardId: cardId,
            outcome: resultOutcome, undoRegistered: true, revision: updated.revision,
            card: updatedCard.map { boardQueryCard($0, checkout: handle) },
            cardTitle: updatedCard?.title ?? titleBeforeChange,
            columnName: updatedCard.flatMap { card in updated.orderedColumns.first { $0.id == card.columnId }?.name },
            assigneeName: updatedCard?.assignee.flatMap { supervisor.records[$0]?.humanDisplayName })
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
        var result = BoardQueryCard(
            cardId: card.id, columnId: card.columnId, title: card.title, body: card.body,
            links: card.links.compactMap { boardAPILink($0, fallbackCheckout: checkout) },
            attachments: card.attachments, assigneeAgentId: card.assignee,
            createdAt: card.createdAt, updatedAt: card.updatedAt)
        result.assigneeAgentIds = card.assignees
        result.comments = card.comments
        return result
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

// MARK: - board.manage

/// What deleting one board takes away, and so what its Undo puts back: the
/// document as it was, and the one tile showing it (zone and WORLD frame).
struct BoardRemovalPlan {
    struct OpenTile { let id: UUID; let zoneId: UUID; let worldFrame: TileFrame }
    let board: Board
    let tile: OpenTile?
}

extension WorkspaceAPIService {
    /// `board.manage`: the Boards sidebar's New, Rename and Delete. Rename is a
    /// document edit and rides `board.apply`'s grant and the board's own undo
    /// history. Create and delete change which tiles exist, so they are
    /// approval-gated like `canvas.apply` and undo on the canvas history.
    func boardManage(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle, requestId: String,
        payload: [String: Any], runtime: WorkspaceRuntime, canvas: CanvasNSView,
        isCancelled: () -> Bool
    ) -> Reply {
        let request: BoardManageRequest
        do {
            request = try Self.decoder.decode(BoardManageRequest.self, from: JSONSerialization.data(withJSONObject: payload))
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "The board change could not be decoded: \(error.localizedDescription)"))
        }
        guard !request.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.idempotencyKey.utf8.count <= 128 else {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "idempotencyKey is required and must be at most 128 bytes."))
        }
        var normalized = request
        normalized.idempotencyKey = ""
        let payloadHash = (try? Self.encoder.encode(normalized)).map { String(decoding: $0, as: UTF8.self) } ?? UUID().uuidString
        if let cached = boardManageIdempotency[agentId]?[request.idempotencyKey] {
            guard cached.payloadHash == payloadHash else {
                return .error(WorkspaceAPIError(code: .idempotencyConflict, message: "That idempotency key was already used for a different board change."))
            }
            guard let object = Self.jsonObject(cached.result) else {
                return .error(WorkspaceAPIError(code: .unsupported, message: "The remembered board result could not be encoded."))
            }
            return .result(object)
        }

        let outcome: Result<BoardManageResult, WorkspaceAPIError>
        do {
            switch request.op {
            case .rename:
                outcome = try boardRename(agentId: agentId, record: record, ownHandle: ownHandle,
                                          requestId: requestId, request: request, isCancelled: isCancelled)
            case .create:
                outcome = try boardCreate(agentId: agentId, record: record, ownHandle: ownHandle,
                                          requestId: requestId, request: request, runtime: runtime,
                                          canvas: canvas, isCancelled: isCancelled)
            case .delete:
                outcome = try boardDelete(agentId: agentId, record: record, ownHandle: ownHandle,
                                          requestId: requestId, request: request, runtime: runtime,
                                          canvas: canvas, isCancelled: isCancelled)
            }
        } catch let failure as BoardRequestFailure {
            return .error(WorkspaceAPIError(code: failure.code, message: failure.message))
        } catch is CancellationError {
            remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .boardManage, outcome: "cancelledBeforeEffect"))
            return .cancelled(result: nil)
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: error.localizedDescription))
        }
        let result: BoardManageResult
        switch outcome {
        case let .failure(error): return .error(error)
        case let .success(value): result = value
        }
        boardManageIdempotency[agentId, default: [:]][request.idempotencyKey] = CachedBoardManage(payloadHash: payloadHash, result: result)
        boardManageIdempotencyOrder[agentId, default: []].append(request.idempotencyKey)
        while (boardManageIdempotencyOrder[agentId]?.count ?? 0) > Self.idempotencyCapacity {
            let evicted = boardManageIdempotencyOrder[agentId]!.removeFirst()
            boardManageIdempotency[agentId]?[evicted] = nil
        }
        remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .boardManage, outcome: "committed", tileId: result.tileId))
        if isCancelled() { return .cancelled(result: Self.jsonObject(result)) }
        guard let object = Self.jsonObject(result) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "The board result could not be encoded."))
        }
        return .result(object)
    }

    // MARK: rename

    private func boardRename(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle, requestId: String,
        request: BoardManageRequest, isCancelled: () -> Bool
    ) throws -> Result<BoardManageResult, WorkspaceAPIError> {
        guard request.nextToTileId == nil else {
            throw BoardRequestFailure("rename accepts only boardId, expectedRevision and title.")
        }
        guard let boardId = request.boardId, let expected = request.expectedRevision else {
            throw BoardRequestFailure("rename requires boardId and expectedRevision.")
        }
        let title = try validatedBoardName(request.title, required: true)!
        let handle = request.checkoutHandle ?? ownHandle
        guard case .allowed = WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .boardApply, checkout: handle, requested: .preserveAll,
            grants: grants[agentId] ?? [], currentGeneration: revocationGeneration(for: agentId)) else {
            throw BoardRequestFailure("This agent may not change that project's boards.", code: .permissionDenied)
        }
        guard let projectId = projectID(for: handle, ownHandle: ownHandle, record: record),
              let boardRuntime = boardRuntimeProvider(projectId),
              let board = boardRuntime.board(id: boardId) else {
            throw BoardRequestFailure("No board with that id exists in this agent's project.", code: .notFound)
        }
        guard expected == board.revision else {
            throw BoardRequestFailure("expectedRevision \(expected) does not match board revision \(board.revision). Re-query before writing.", code: .revisionConflict)
        }
        func result(_ board: Board, undo: Bool) -> BoardManageResult {
            BoardManageResult(
                operationId: requestId, op: .rename, boardId: boardId,
                tileId: boardRuntime.boardIndexEntries().first(where: { $0.id == boardId })?.tileId,
                title: board.title, revision: board.revision, columns: boardColumns(board), undoRegistered: undo)
        }
        // Already called that: nothing to commit and nothing to undo.
        if board.title == title { return .success(result(board, undo: false)) }

        _beforeCommitHook?()
        if isCancelled() { throw CancellationError() }
        guard supervisor.records[agentId]?.workspaceToolsEnabled == true else {
            throw BoardRequestFailure("Workspace tools were revoked before the board changed.", code: .permissionDenied)
        }
        guard let current = boardRuntime.board(id: boardId), current.revision == expected else {
            throw BoardRequestFailure("The board changed before it could be renamed. Re-query before writing.", code: .revisionConflict)
        }
        // The sidebar's own rename: the reducer, persistence, live tiles, the
        // index title (whence the Boards sidebar and the tile header), one undo.
        switch boardRuntime.apply(.renameBoard(title: title), to: boardId, actingAgent: agentId) {
        case .applied, .rebased: break
        case .rejectedCardHeldByPointer:
            throw BoardRequestFailure("The user is dragging a task on this board. Re-query after the gesture ends.", code: .busy)
        case .persistenceFailed:
            remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .boardManage, outcome: "durabilityFailed"))
            throw BoardRequestFailure("The board could not be saved, so the rename was rolled back.", code: .durabilityFailed)
        case .rejected(let error):
            return .failure(boardError(error))
        }
        guard let updated = boardRuntime.board(id: boardId) else {
            throw BoardRequestFailure("The board committed but its result could not be read.", code: .outcomeUnknown)
        }
        return .success(result(updated, undo: true))
    }

    // MARK: create

    private func boardCreate(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle, requestId: String,
        request: BoardManageRequest, runtime: WorkspaceRuntime, canvas: CanvasNSView,
        isCancelled: () -> Bool
    ) throws -> Result<BoardManageResult, WorkspaceAPIError> {
        guard request.boardId == nil, request.expectedRevision == nil else {
            throw BoardRequestFailure("create takes no boardId or expectedRevision; Array mints the board.")
        }
        guard (request.checkoutHandle ?? ownHandle) == ownHandle else {
            throw BoardRequestFailure("Boards can be created only in this agent's own project.", code: .permissionDenied)
        }
        guard let projectId = record.projectId ?? knownCheckouts()[ownHandle]?.projectId,
              let ownTile = record.tileId,
              let zoneId = canvas.installedZoneIds(containing: ownTile).onlyBoardZone,
              canvas.projectId(forZone: zoneId) == projectId else {
            throw BoardRequestFailure("This agent's tile must be on the canvas, in its own project's zone, to create a board.", code: .unsupported)
        }
        let anchor = request.nextToTileId ?? ownTile
        guard canvas.installedZoneIds(containing: anchor) == [zoneId] else {
            throw BoardRequestFailure("nextToTileId must name a tile in this agent's own zone.")
        }
        // The UI's own default: the zone's name, or "New Board".
        let title = try validatedBoardName(request.title, required: false)
            ?? AppDelegate.boardTitle(forZoneTitle: canvas.zonePresentation(for: zoneId)?.title ?? "")

        let approval = try authorizeBoardManage(agentId: agentId, record: record, ownHandle: ownHandle,
                                                requestId: requestId, isCancelled: isCancelled)
        _beforeCommitHook?()
        if isCancelled() { throw CancellationError() }
        try recheckBoardManage(agentId: agentId, generation: approval.generation)
        guard canvas.installedZoneIds(containing: anchor) == [zoneId], canvas.projectId(forZone: zoneId) == projectId else {
            throw BoardRequestFailure("The tile left this agent's zone before the board was created.", code: .targetConflict)
        }
        guard !canvas.isGeometryGestureActive else {
            throw BoardRequestFailure("gesture_active: the user is moving or resizing on the canvas. Wait and try again.", code: .targetConflict)
        }
        let spawner: TileSpawner
        do { spawner = try runtime.ensureSpawner(forProjectId: projectId) }
        catch { throw BoardRequestFailure("This project's canvas is unavailable.", code: .unsupported) }
        // One Undo for the board AND the settle its spawn makes. The step is
        // registered first so it runs last: the settle is undone while the tile
        // it moved is still there, then the board goes.
        let created = CreatedBoardBox()
        var undo = false
        var spawned: (boardId: UUID, tileId: UUID)?
        canvas.withCanvasUndoGroup(actionName: "New Board", token: created) {
            undo = registerBoardLifecycleUndo(.removeCreated(created), projectId: projectId, name: "New Board",
                                              canvas: canvas, token: created)
            guard case let .spawned(boardId, tileId) = spawner.spawnAgentBoard(title: title, beside: anchor, targetZoneId: zoneId) else {
                return false
            }
            created.boardId = boardId
            spawned = (boardId, tileId)
            return true
        }
        guard let (boardId, tileId) = spawned,
              let boardRuntime = boardRuntimeProvider(projectId), let board = boardRuntime.board(id: boardId) else {
            remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .boardManage, outcome: "durabilityFailed"))
            throw BoardRequestFailure("The board could not be created and saved; nothing was kept.", code: .durabilityFailed)
        }
        return .success(BoardManageResult(
            operationId: requestId, op: .create, boardId: boardId, tileId: tileId,
            zoneId: canvas.zoneId(containing: tileId), title: board.title, revision: board.revision,
            columns: boardColumns(board), undoRegistered: undo))
    }

    // MARK: delete

    private func boardDelete(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle, requestId: String,
        request: BoardManageRequest, runtime: WorkspaceRuntime, canvas: CanvasNSView,
        isCancelled: () -> Bool
    ) throws -> Result<BoardManageResult, WorkspaceAPIError> {
        guard request.title == nil, request.nextToTileId == nil else {
            throw BoardRequestFailure("delete accepts only boardId and expectedRevision.")
        }
        guard let boardId = request.boardId, let expected = request.expectedRevision else {
            throw BoardRequestFailure("delete requires boardId and expectedRevision.")
        }
        guard (request.checkoutHandle ?? ownHandle) == ownHandle else {
            throw BoardRequestFailure("Boards can be deleted only in this agent's own project.", code: .permissionDenied)
        }
        guard let projectId = record.projectId ?? knownCheckouts()[ownHandle]?.projectId else {
            throw BoardRequestFailure("No board with that id exists in this agent's project.", code: .notFound)
        }
        func plan() throws -> BoardRemovalPlan {
            let plan = try boardRemovalPlan(projectId: projectId, boardId: boardId, runtime: runtime, canvas: canvas)
            guard plan.board.revision == expected else {
                throw BoardRequestFailure("expectedRevision \(expected) does not match board revision \(plan.board.revision). Re-query before writing.", code: .revisionConflict)
            }
            return plan
        }
        _ = try plan()
        let approval = try authorizeBoardManage(agentId: agentId, record: record, ownHandle: ownHandle,
                                                requestId: requestId, isCancelled: isCancelled)
        _beforeCommitHook?()
        if isCancelled() { throw CancellationError() }
        try recheckBoardManage(agentId: agentId, generation: approval.generation)
        let removal = try plan()
        if let error = executeBoardRemoval(removal, projectId: projectId) {
            remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .boardManage, outcome: "durabilityFailed"))
            return .failure(error)
        }
        let undo = registerBoardLifecycleUndo(.restore(removal), projectId: projectId, name: "Delete Board", canvas: canvas)
        return .success(BoardManageResult(
            operationId: requestId, op: .delete, boardId: boardId, tileId: nil,
            title: removal.board.title, revision: removal.board.revision,
            columns: boardColumns(removal.board), undoRegistered: undo))
    }

    /// Everything a delete must prove before its first effect. Refuses a board
    /// that still holds tasks: the sidebar asks the user before deleting tasks,
    /// and an agent has no such dialog, so the most it may take is an empty
    /// board's name and columns. Refuses a tile the user is in, or one the
    /// canvas has not installed — the sidebar would reveal it, which the API
    /// never does.
    func boardRemovalPlan(projectId: UUID, boardId: UUID, runtime: WorkspaceRuntime, canvas: CanvasNSView) throws -> BoardRemovalPlan {
        guard let boardRuntime = boardRuntimeProvider(projectId),
              boardRuntime.boardIndexEntries().contains(where: { $0.id == boardId }),
              let board = boardRuntime.board(id: boardId) else {
            throw BoardRequestFailure("No board with that id exists in this agent's project.", code: .notFound)
        }
        guard board.cards.isEmpty else {
            throw BoardRequestFailure("board_not_empty: this board still has \(board.cards.count) task(s). Array deletes only empty boards for an agent; delete or move each task with array_board_apply first, or leave it for the user.", code: .targetConflict)
        }
        let tiles: [Tile]
        do { tiles = try runtime.ensureSpawner(forProjectId: projectId).savedBoardTiles().filter { $0.metadata.boardId == boardId } }
        catch { throw BoardRequestFailure("This project's canvas could not be read.", code: .unsupported) }
        guard tiles.count <= 1 else { throw BoardRequestFailure("duplicate_occurrence", code: .unsupported) }
        guard let tile = tiles.first else { return BoardRemovalPlan(board: board, tile: nil) }
        guard let zoneId = canvas.installedZoneIds(containing: tile.id).onlyBoardZone,
              canvas.projectId(forZone: zoneId) == projectId,
              canvas.tileView(for: tile.id) is KanbanTileNSView,
              let world = canvas.tilesInWorldFrames(forZoneId: zoneId)?.first(where: { $0.id == tile.id })?.frame else {
            throw BoardRequestFailure("zone_unhydrated: the board's tile is in a zone that is not on the canvas now.", code: .unsupported)
        }
        guard focusBrokerProvider()?.activeSurface != .tile(tile.id),
              !canvas.tileSelection.ids.contains(tile.id), !canvas.isGeometryGestureActive else {
            throw BoardRequestFailure("board_in_use: the user is working in this board's tile. Try again later.", code: .targetConflict)
        }
        return BoardRemovalPlan(board: board, tile: .init(id: tile.id, zoneId: zoneId, worldFrame: world))
    }

    /// The sidebar's delete without its dialog: close the tile, then delete the
    /// closed document. A failed document delete reopens the tile it closed.
    private func executeBoardRemoval(_ plan: BoardRemovalPlan, projectId: UUID) -> WorkspaceAPIError? {
        guard let boardRuntime = boardRuntimeProvider(projectId) else {
            return WorkspaceAPIError(code: .unsupported, message: "That project's board runtime is unavailable.")
        }
        if let tile = plan.tile, !boardTileCloser(tile.id) {
            return WorkspaceAPIError(code: .durabilityFailed, message: "The board's tile could not be closed, so nothing was deleted.")
        }
        do { try boardRuntime.deleteClosedBoard(id: plan.board.id) }
        catch {
            if let tile = plan.tile, let spawner = try? runtimeProvider()?.ensureSpawner(forProjectId: projectId) {
                _ = spawner.reopenBoardTile(plan.board, tileId: tile.id, worldFrame: tile.worldFrame, targetZoneId: tile.zoneId)
            }
            return WorkspaceAPIError(code: .durabilityFailed, message: "The board could not be deleted: \(error.localizedDescription)")
        }
        return nil
    }

    private func restoreRemovedBoard(_ plan: BoardRemovalPlan, projectId: UUID) -> Bool {
        guard let boardRuntime = boardRuntimeProvider(projectId), boardRuntime.restoreBoard(plan.board) != nil else { return false }
        if let tile = plan.tile, let spawner = try? runtimeProvider()?.ensureSpawner(forProjectId: projectId) {
            // A zone no longer installed leaves the board closed, in the sidebar.
            _ = spawner.reopenBoardTile(plan.board, tileId: tile.id, worldFrame: tile.worldFrame, targetZoneId: tile.zoneId)
        }
        return true
    }

    enum BoardLifecycleStep {
        case remove(UUID)
        /// A create's Undo, registered before the board exists.
        case removeCreated(CreatedBoardBox)
        case restore(BoardRemovalPlan)
    }

    final class CreatedBoardBox { var boardId: UUID? }

    /// Registers `step` as the Undo of the change just made, and its opposite as
    /// the Redo when it runs. A step the board no longer permits (tasks added to
    /// a created board, its tile in use) changes nothing and is spent.
    private func registerBoardLifecycleUndo(
        _ step: BoardLifecycleStep, projectId: UUID, name: String, canvas: CanvasNSView, token: AnyObject? = nil
    ) -> Bool {
        canvas.registerCanvasUndo(actionName: name, token: token) { [weak self] canvas in
            guard let self, let runtime = self.runtimeProvider() else { return }
            switch step {
            case let .removeCreated(box):
                guard let boardId = box.boardId,
                      let plan = try? self.boardRemovalPlan(projectId: projectId, boardId: boardId, runtime: runtime, canvas: canvas),
                      self.executeBoardRemoval(plan, projectId: projectId) == nil else { return }
                _ = self.registerBoardLifecycleUndo(.restore(plan), projectId: projectId, name: name, canvas: canvas)
            case let .remove(boardId):
                guard let plan = try? self.boardRemovalPlan(projectId: projectId, boardId: boardId, runtime: runtime, canvas: canvas),
                      self.executeBoardRemoval(plan, projectId: projectId) == nil else { return }
                _ = self.registerBoardLifecycleUndo(.restore(plan), projectId: projectId, name: name, canvas: canvas)
            case let .restore(plan):
                guard self.restoreRemovedBoard(plan, projectId: projectId) else { return }
                _ = self.registerBoardLifecycleUndo(.remove(plan.board.id), projectId: projectId, name: name, canvas: canvas)
            }
        }
    }

    // MARK: grants

    /// `canvas.apply`'s approval, for `board.manage` create and delete: the
    /// first one in a session asks under Ask first; Free approves inside the
    /// caller's own project; "allow once" is spent by this request.
    private func authorizeBoardManage(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle, requestId: String,
        isCancelled: () -> Bool
    ) throws -> (requestId: String?, generation: UInt64) {
        func allowed() -> Bool {
            if case .allowed = WorkspaceToolGrantEvaluator.evaluate(
                agentId: agentId, op: .boardManage, checkout: ownHandle, requested: .preserveAll,
                grants: grants[agentId] ?? [], currentGeneration: revocationGeneration(for: agentId)) { return true }
            return false
        }
        var promptId: String?
        if !allowed() {
            let id = UUID().uuidString
            promptId = id
            let decision = decideScope(ScopeApprovalPrompt(
                requestId: id, agentId: agentId, agentDisplayName: record.displayName,
                checkout: ownHandle, checkoutDisplayName: knownCheckouts()[ownHandle]?.displayName ?? record.displayName,
                op: .boardManage, relativePath: nil),
                withinCallerProject: true)
            if isCancelled() { throw CancellationError() }
            guard supervisor.records[agentId]?.workspaceToolsEnabled == true else {
                throw BoardRequestFailure("Workspace tools were disabled for this agent.", code: .permissionDenied)
            }
            switch decision {
            case .deny:
                throw BoardRequestFailure("The user has not allowed this agent to create or delete boards. Nothing was changed.", code: .scopeApprovalRequired)
            case .allowOnce:
                mint(WorkspaceToolGrant(
                    agentId: agentId, checkoutHandles: [ownHandle], operations: [.boardManage],
                    presentationCeiling: .preserveAll, issuer: .userApprovalOnce(requestId: id),
                    revocationGeneration: revocationGeneration(for: agentId), singleUse: true))
            case .allowForSession, .allowForProjectSession, .allowByPolicy:
                mint(WorkspaceToolGrant(
                    agentId: agentId, checkoutHandles: [ownHandle], operations: [.boardManage],
                    presentationCeiling: .preserveAll, issuer: Self.sessionIssuer(decision, requestId: id),
                    revocationGeneration: revocationGeneration(for: agentId)))
            }
            guard allowed() else { throw BoardRequestFailure("Approval did not take.", code: .permissionDenied) }
        }
        // Spend a once-grant unless a durable grant also covers the checkout.
        if var live = grants[agentId] {
            let durable = live.contains { !$0.singleUse && $0.checkoutHandles.contains(ownHandle) && $0.operations.contains(.boardManage) && $0.revocationGeneration == revocationGeneration(for: agentId) }
            if !durable, let index = live.firstIndex(where: { $0.singleUse && $0.checkoutHandles.contains(ownHandle) && $0.operations.contains(.boardManage) }) {
                live.remove(at: index)
                grants[agentId] = live
            }
        }
        return (promptId, revocationGeneration(for: agentId))
    }

    private func recheckBoardManage(agentId: AgentID, generation: UInt64) throws {
        guard supervisor.records[agentId]?.workspaceToolsEnabled == true,
              revocationGeneration(for: agentId) == generation else {
            throw BoardRequestFailure("Workspace tools were revoked before the board changed.", code: .permissionDenied)
        }
    }

    private func validatedBoardName(_ title: String?, required: Bool) throws -> String? {
        guard let title else {
            if required { throw BoardRequestFailure("rename requires title.") }
            return nil
        }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 200, !value.contains(where: \.isNewline) else {
            throw BoardRequestFailure("A board name must be one non-empty line of at most 200 bytes.")
        }
        return value
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

private extension Array {
    /// The single element, or nil for none or several (a tile in two layers).
    var onlyBoardZone: Element? { count == 1 ? first : nil }
}
