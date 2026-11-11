import ContinuumRevivedCore
import Foundation

extension WorkspaceAPIService {
    /// `standards.read` (`docs/internals/project-standards-on-demand.md`): the
    /// caller reads its OWN checkout's `docs/standards`. The request names no
    /// checkout and no path; ids are looked up in the scanned index. Identity,
    /// grant and validation are checked on the main actor; listing, reading and
    /// parsing run off it, through `ProjectStandardsCache`, and the reply is
    /// completed on the main actor when they are done. Needs no mounted canvas.
    func dispatchStandardsRead(agentId: AgentID, payload: [String: Any], completion: @escaping (Reply) -> Void) {
        guard let raw = supervisor.records[agentId] else {
            completion(.error(WorkspaceAPIError(code: .permissionDenied, message: "Unknown caller.")))
            return
        }
        guard raw.workspaceToolsEnabled else {
            completion(.error(WorkspaceAPIError(code: .permissionDenied, message: "Workspace tools are not enabled for this agent. The user can enable them from the agent's menu in Array.")))
            return
        }
        let record = resolvedRecord(raw)
        let ownHandle = Self.ownCheckoutHandle(record)
        seedGrantsIfNeeded(agentId: agentId, checkout: ownHandle)
        dropPolicyGrantsUnlessFree(agentId: agentId)
        guard case .allowed = WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .standardsRead, checkout: ownHandle, requested: .preserveAll,
            grants: grants[agentId] ?? [], currentGeneration: revocationGeneration(for: agentId)) else {
            completion(.error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not read standards.")))
            return
        }
        let request: StandardsReadRequest
        switch StandardsReadRequest.validated(payload: payload) {
        case .failure(let error): completion(.error(error)); return
        case .success(let value): request = value
        }
        let checkout = URL(fileURLWithPath: record.checkoutRoot, isDirectory: true)
        Task { @MainActor in
            let outcome = await Self.answerOffMain(request, checkout: checkout)
            switch outcome {
            case nil:
                completion(.error(WorkspaceAPIError(code: .notFound, message: "This checkout has no \(ProjectStandards.directory) directory.")))
            case .failure(let error)?:
                completion(.error(error))
            case .page(let page)?:
                guard let object = Self.jsonObject(page) else {
                    completion(.error(WorkspaceAPIError(code: .unsupported, message: "The standards could not be encoded.")))
                    return
                }
                completion(.result(object))
            }
        }
    }

    /// Listing, reading and parsing, off the main actor.
    nonisolated static func answerOffMain(_ request: StandardsReadRequest, checkout: URL) async -> StandardsReadPage.Outcome? {
        await Task.detached(priority: .userInitiated) {
            // Part 12/14 seam: a retrieval fact (agent, ids, versions; never text) is appended here once a ledger exists.
            ProjectStandardsCache.shared.index(checkoutRoot: checkout).map { StandardsReadPage.answer(request, index: $0) }
        }.value
    }
}
