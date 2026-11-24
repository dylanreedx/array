import ContinuumRevivedCore
import ContinuumRevivedAgentUI
import Foundation

// Boards stay current without anyone remembering (`BoardUpkeep`): a delegated
// task is assigned and moved to Doing, a helper's report lands on its card, and
// a card nobody is working on any more shows as stale and nudges its lead once.
// Every write goes through `BoardRuntime.apply`, so it persists, broadcasts to
// open tiles and joins the board's undo like any other change.
extension WorkspaceAPIService {
    struct DelegatedCard {
        let runtime: BoardRuntime
        let boardId: UUID
        let cardId: UUID
        let title: String
    }

    /// The task a delegation names, in the caller's own project. Without a
    /// boardId every board of the project is searched.
    func resolveDelegatedCard(cardId: UUID, boardId: UUID?, record: AgentRecord) -> Result<DelegatedCard, WorkspaceAPIError> {
        guard let projectId = record.projectId, let runtime = boardRuntimeProvider(projectId) else {
            return .failure(WorkspaceAPIError(code: .unsupported, message: "This agent's project has no board runtime, so cardId cannot be used."))
        }
        let boards = runtime.boardIndexEntries().map(\.id).filter { boardId == nil || $0 == boardId }
        for id in boards {
            if let card = runtime.board(id: id)?.card(cardId) {
                return .success(DelegatedCard(runtime: runtime, boardId: id, cardId: cardId, title: card.title))
            }
        }
        return .failure(WorkspaceAPIError(code: .notFound, message: "No task with that cardId exists on \(boardId == nil ? "any board in" : "that board of") this agent's project. Nothing was delegated."))
    }

    /// Assigns the new helper and moves the task to Doing, as the lead. A task
    /// already past Doing is reopened there; Array never moves one to Done.
    func adoptDelegatedCard(_ card: DelegatedCard, child: AgentID, lead: AgentID) {
        delegatedCardLeads[card.cardId] = lead
        guard let board = card.runtime.board(id: card.boardId), let current = board.card(card.cardId) else { return }
        // Acting as the child: it already holds the task in its first prompt,
        // so nothing stages it in its composer as an unsent hand-off.
        if !current.assignees.contains(child) {
            _ = card.runtime.apply(.setCardAssignees(id: card.cardId, agents: current.assignees + [child]),
                                   to: card.boardId, actingAgent: child)
        }
        guard let doing = BoardUpkeep.doingColumn(board), current.columnId != doing,
              let latest = card.runtime.board(id: card.boardId) else { return }
        _ = card.runtime.apply(.moveCard(id: card.cardId, toColumn: doing,
                                         after: latest.orderedCards(in: doing).last?.id, before: nil),
                               to: card.boardId, actingAgent: lead)
    }

    /// Every task on `agentId`'s project boards that names it as an assignee.
    private func assignedCards(_ agentId: AgentID) -> [(BoardRuntime, UUID, BoardCard)] {
        guard let projectId = supervisor.records[agentId]?.projectId, let runtime = boardRuntimeProvider(projectId) else { return [] }
        return runtime.boardIndexEntries().flatMap { entry -> [(BoardRuntime, UUID, BoardCard)] in
            (runtime.board(id: entry.id)?.cards ?? []).filter { $0.assignees.contains(agentId) }.map { (runtime, entry.id, $0) }
        }
    }

    /// One comment, authored by the helper, on each task it is assigned to.
    /// The id is derived from what it reports, so a second post is refused by
    /// the board itself and nothing is written twice.
    private func postOnAssignedCards(_ agentId: AgentID, commentId: UUID, body: String, at date: Date) {
        guard let record = supervisor.records[agentId] else { return }
        for (runtime, boardId, card) in assignedCards(agentId) where !card.comments.contains(where: { $0.id == commentId }) {
            var comment = BoardComment(id: commentId, authorID: agentId.rawValue.uuidString.lowercased(),
                                       authorName: record.humanDisplayName, createdAt: date, body: body)
            let identity = boardCommentIdentity(record, dark: true)
            comment.authorColour = identity["colour"] as? String
            comment.authorCharacter = identity["character"] as? String
            _ = runtime.apply(.addComment(cardID: card.id, comment: comment), to: boardId, actingAgent: agentId)
        }
    }

    /// A helper's filed report, as a comment on its tasks.
    func postReportOnAssignedCards(_ agentId: AgentID) {
        guard let record = supervisor.records[agentId], record.parentAgentID != nil, let filed = record.lastReport else { return }
        let body = BoardUpkeep.reportCommentBody(filed.report)
        let runStart = record.latestPromptAt ?? record.createdAt
        postOnAssignedCards(agentId, commentId: BoardUpkeep.reportCommentID(agent: agentId, runStartedAt: runStart, body: body),
                            body: body, at: filed.filedAt)
    }

    /// A helper's run ended: its report if it filed one in this run, otherwise
    /// one line saying how the run ended.
    func helperRunEnded(_ agentId: AgentID) {
        guard let record = supervisor.records[agentId], record.parentAgentID != nil,
              let ended = record.latestTerminalEvent else { return }
        let runStart = record.latestPromptAt ?? record.createdAt
        if let filed = record.lastReport, filed.filedAt >= runStart {
            postReportOnAssignedCards(agentId)
        } else {
            let outcome = ended.outcome == .succeeded ? "ended" : ended.outcome == .failed || ended.outcome == .runtimeError ? "failed" : "stopped"
            postOnAssignedCards(agentId, commentId: BoardUpkeep.runEndCommentID(agent: agentId, endedAt: ended.endedAt),
                                body: BoardUpkeep.runEndCommentBody(outcome: outcome), at: ended.endedAt)
        }
        sweepBoardUpkeep()
    }

    func installBoardUpkeepObserver() {
        guard boardUpkeepObserver == nil else { return }
        boardUpkeepObserver = supervisor.addDeliveredEventObserver { [weak self] agentId, event in
            guard case .turnCompleted = event else { return }
            // After the supervisor has finished this event: the record then
            // carries the run's terminal outcome.
            DispatchQueue.main.async { [weak self] in self?.helperRunEnded(agentId) }
        }
    }

    /// Production only: the sweep that marks a task stale with no event to
    /// trigger it (time passing). Checks call `sweepBoardUpkeep` directly.
    func startBoardUpkeep() {
        installBoardUpkeepObserver()
        guard boardUpkeepTimer == nil else { return }
        boardUpkeepTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepBoardUpkeep() }
        }
    }

    private func assigneeState(_ id: AgentID) -> (BoardUpkeep.AssigneeState, Date?) {
        guard let record = supervisor.records[id], record.archivedAt == nil, record.closeRequestedAt == nil else { return (.vanished, nil) }
        if supervisor.isRunning(id) { return (.working, nil) }
        let lastActive = [record.latestTerminalEvent?.endedAt, record.latestTurnAt, record.latestPromptAt].compactMap { $0 }.max()
        guard let ended = record.latestTerminalEvent, ended.endedAt >= (record.latestPromptAt ?? record.createdAt) else {
            return (.idle, lastActive)
        }
        if ended.outcome != .succeeded { return (.stopped, lastActive) }
        return (record.parentAgentID != nil ? .finished : .idle, lastActive)
    }

    /// Marks every stale task on the mounted projects' boards and sends each
    /// newly stale one's lead a single message through the agent-message path.
    @discardableResult
    func sweepBoardUpkeep() -> Set<UUID> {
        let now = boardUpkeepNow()
        var stale: Set<UUID> = []
        for projectId in runtimeProvider()?.mountedProjectIds ?? [] {
            guard let runtime = boardRuntimeProvider(projectId) else { continue }
            var projectStale: Set<UUID> = []
            for entry in runtime.boardIndexEntries() {
                guard let board = runtime.board(id: entry.id) else { continue }
                for card in board.cards where !card.assignees.isEmpty {
                    var states: [AgentID: BoardUpkeep.AssigneeState] = [:]
                    var touched = card.updatedAt
                    for id in card.assignees {
                        let (state, active) = assigneeState(id)
                        states[id] = state
                        if let active, active > touched { touched = active }
                    }
                    guard BoardUpkeep.isStale(card, in: board, assignees: states, lastTouched: touched, now: now) else { continue }
                    projectStale.insert(card.id)
                    nudgeLeadOnce(card: card, board: board)
                }
            }
            runtime.setStaleCards(projectStale)
            stale.formUnion(projectStale)
        }
        staleCardIDs = stale
        return stale
    }

    /// One message per stale episode: a task touched again and gone stale
    /// again is a new episode. The lead is the assignee's parent, or the lead
    /// that delegated this task if the helper is gone.
    private func nudgeLeadOnce(card: BoardCard, board: Board) {
        let episode = "\(card.id.uuidString)|\(card.updatedAt.timeIntervalSince1970)"
        guard !boardUpkeepNudged.contains(episode) else { return }
        for helper in card.assignees {
            guard let lead = supervisor.records[helper]?.parentAgentID ?? delegatedCardLeads[card.id],
                  supervisor.records[lead] != nil else { continue }
            let text = BoardUpkeep.nudgeText(cardTitle: card.title, boardTitle: board.title, boardId: board.id, cardId: card.id)
            if supervisor.sendAgentMessage(text, from: helper, to: lead) {
                boardUpkeepNudged.insert(episode)
                boardUpkeepNudgeCount += 1
            }
            return
        }
    }
}
