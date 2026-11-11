import ContinuumRevivedCore
import Foundation

extension WorkspaceAPIService {
    /// `standards.read` (`docs/internals/project-standards-on-demand.md`): the
    /// caller reads its OWN checkout's `docs/standards`. The request names no
    /// checkout and no path; ids are looked up in the scanned index, and every
    /// file goes through `AgentLocalFileLinkResolver`. Read only: presents,
    /// navigates and records nothing but the shadow observation below.
    func readStandards(agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle, payload: [String: Any]) -> Reply {
        guard case .allowed = WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .standardsRead, checkout: ownHandle, requested: .preserveAll,
            grants: grants[agentId] ?? [], currentGeneration: revocationGeneration(for: agentId)) else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not read standards."))
        }
        let request: StandardsReadRequest
        switch StandardsReadRequest.validated(payload: payload) {
        case .failure(let error): return .error(error)
        case .success(let value): request = value
        }
        let checkout = URL(fileURLWithPath: record.checkoutRoot, isDirectory: true)
        guard let index = ProjectStandards.scan(checkoutRoot: checkout) else {
            return .error(WorkspaceAPIError(code: .notFound, message: "This checkout has no \(ProjectStandards.directory) directory."))
        }
        let result = StandardsReadResult.answer(request, index: index)
        // Part 12/14 seam: a retrieval fact (agent, ids, versions; never text) is appended here once a ledger exists.
        guard let object = Self.jsonObject(result) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "The standards could not be encoded."))
        }
        return .result(object)
    }
}
