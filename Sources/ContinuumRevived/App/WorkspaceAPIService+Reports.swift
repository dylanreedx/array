import ContinuumRevivedCore
import Foundation

extension WorkspaceAPIService {
    /// `.plans/102` P2a, `agent.report`: the caller files a report on its own
    /// work. Self-only by construction (the request names no agent), so another
    /// agent's token can only ever file on that other agent. Record only: never
    /// presents, navigates or touches a runner.
    func fileReport(agentId: AgentID, ownHandle: CheckoutHandle, payload: [String: Any]) -> Reply {
        guard case .allowed = WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .agentReport, checkout: ownHandle, requested: .preserveAll,
            grants: grants[agentId] ?? [], currentGeneration: revocationGeneration(for: agentId)) else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not file a report."))
        }
        switch AgentReport.validated(payload: payload) {
        case .failure(let error):
            return .error(error)
        case .success(let report):
            guard supervisor.fileReport(report, for: agentId), let object = Self.jsonObject(AgentReportResult(recorded: true)) else {
                return .error(WorkspaceAPIError(code: .unsupported, message: "The report could not be recorded."))
            }
            return .result(object)
        }
    }

    /// `.plans/102` P2a, `agent.status`: the caller declares what it is doing.
    /// Stored as DECLARED, beside (never merged into) the observed status.
    func declareStatus(agentId: AgentID, ownHandle: CheckoutHandle, payload: [String: Any]) -> Reply {
        guard case .allowed = WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .agentStatus, checkout: ownHandle, requested: .preserveAll,
            grants: grants[agentId] ?? [], currentGeneration: revocationGeneration(for: agentId)) else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not post a status."))
        }
        switch AgentDeclaredStatus.validated(payload: payload, at: Date()) {
        case .failure(let error):
            return .error(error)
        case .success(let status):
            guard supervisor.declareStatus(status, for: agentId), let object = Self.jsonObject(status) else {
                return .error(WorkspaceAPIError(code: .unsupported, message: "The status could not be recorded."))
            }
            return .result(object)
        }
    }

    /// `.plans/102`: managed lead decisions, then the opt-in report policy.
    /// Free agents with short reports off retain the empty P1 reply.
    func hookReply(for record: AgentRecord, payload: [String: Any]) -> [String: Any] {
        if let output = supervisor.managedHookReply(for: record, payload: payload) {
            return [WorkspaceAgentHook.hookOutputKey: output]
        }
        guard shortReportsEnabled(),
              let output = WorkspaceAgentHook.reportPushBack(payload: payload, callerHasParent: record.parentAgentID != nil) else {
            return [:]
        }
        if record.harness == .codex,
           !supervisor.claimCodexHookPushBack(for: record.id, payload: payload) { return [:] }
        return [WorkspaceAgentHook.hookOutputKey: output]
    }

    /// `operation.get`'s child result. Off, exactly the courier plus any
    /// filed `report`. On, a filed report takes the final text's place, so the
    /// parent reads the short form; the full text stays on the child's tile.
    func childResultForParent(_ file: SpawnResultFile) -> OperationChildResult {
        var result = OperationChildResult(file)
        if result.report != nil, shortReportsEnabled() {
            result.finalText = nil
            result.finalTextTruncated = nil
        }
        return result
    }
}
