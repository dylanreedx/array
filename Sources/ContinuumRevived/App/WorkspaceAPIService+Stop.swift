import ContinuumRevivedCore
import Foundation

extension WorkspaceAPIService {
    /// `agent.stop`: a lead stops helpers it created. Live 2026-11-20: "pause all
    /// agents rn" got "open the helper in the inbox and press Stop", because the
    /// only tool that reached a helper, `agent.message`, queues behind its turn.
    ///
    /// This is the teardown stop (`AgentSupervisor.stop`): the helper's process
    /// ends before this returns. It never holds the helper's queue, so a later
    /// message to the helper starts it again. Scope is the caller's own
    /// DESCENDANTS (children, their children, ...), nothing else; a target out of
    /// that scope is refused with a message that names nothing about other agents.
    func stopHelpers(agentId: AgentID, payload: [String: Any], isCancelled: () -> Bool) -> Reply {
        guard !isCancelled() else { return .error(WorkspaceAPIError(code: .unsupported, message: "Stop request cancelled.")) }
        let wantsAll = (payload["all"] as? Bool) == true
        let rawTarget = (payload["agentId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wantsAll != (rawTarget?.isEmpty == false) else {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "Pass agentId for one helper, or all=true for every helper you created, not both and not neither."))
        }
        func isDescendant(_ id: AgentID) -> Bool {
            var seen: Set<AgentID> = []
            var cursor = supervisor.records[id]?.parentAgentID
            while let parent = cursor, seen.insert(parent).inserted {
                if parent == agentId { return true }
                cursor = supervisor.records[parent]?.parentAgentID
            }
            return false
        }
        var targets: [AgentID]
        if wantsAll {
            targets = supervisor.records.keys.filter { isDescendant($0) }
        } else {
            guard let rawTarget, let uuid = UUID(uuidString: rawTarget), isDescendant(AgentID(rawValue: uuid)) else {
                return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may stop only helpers it created. That agent is not one of them."))
            }
            targets = [AgentID(rawValue: uuid)]
        }
        targets.sort { $0.rawValue.uuidString < $1.rawValue.uuidString }
        var stopped: [[String: Any]] = [], idle: [[String: Any]] = []
        for id in targets {
            let entry: [String: Any] = ["agentId": id.rawValue.uuidString, "name": supervisor.records[id]?.humanDisplayName ?? ""]
            if supervisor.isRunning(id) {
                supervisor.stop(id)
                stopped.append(entry)
            } else {
                idle.append(entry)
            }
        }
        return .result([
            "stopped": AnyHashableJSON(any: stopped),
            "alreadyIdle": AnyHashableJSON(any: idle),
        ])
    }
}
