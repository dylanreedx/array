import ContinuumRevivedCore
import Foundation

struct LeadPlanPresentation: Equatable {
    enum State: String { case waiting = "Waiting", running = "Running", needsYou = "Needs you", failed = "Failed", done = "Done" }
    struct Step: Equatable {
        let title: String
        let owner: String
        let state: State
    }
    let steps: [Step]
    let collapsed: Bool
    var summary: String { "Plan · \(steps.filter { $0.state == .done }.count) of \(steps.count) done" }
    var urgent: Step? {
        for state in [State.needsYou, .failed, .running] {
            if let step = steps.first(where: { $0.state == state }) { return step }
        }
        return nil
    }
    var header: String {
        guard collapsed, let urgent else { return summary }
        return summary + " · \(urgent.state.rawValue): \(urgent.title)"
    }
}

extension AgentSupervisor {
    /// Resolve only this lead's own helpers, by exact ID or unambiguous name.
    /// Persist IDs so a rename cannot silently reassign a step to another helper.
    func resolveLeadPlan(_ plan: [AgentPlanStep], for id: AgentID) -> Result<[AgentPlanStep], WorkspaceAPIError> {
        var resolved = plan
        for i in resolved.indices where !["lead", "you"].contains(resolved[i].owner) {
            let owner = resolved[i].owner
            let matches = records.values.filter {
                $0.parentAgentID == id && ($0.id.rawValue.uuidString.caseInsensitiveCompare(owner) == .orderedSame
                    || $0.humanDisplayName == owner)
            }
            guard matches.count == 1, let helper = matches.first else {
                return .failure(.init(code: .invalidRequest, message: "Plan owner must name one of your helpers (use its ID if names repeat). Nothing was recorded."))
            }
            resolved[i].owner = helper.id.rawValue.uuidString
        }
        return .success(resolved)
    }

    func leadPlan(for id: AgentID) -> LeadPlanPresentation? {
        guard let lead = records[id], lead.mode == .managed, lead.parentAgentID == nil,
              let plan = lead.declaredStatus?.plan, !plan.isEmpty else { return nil }
        let steps = plan.map { step -> LeadPlanPresentation.Step in
            if step.owner == "lead" || step.owner == "you" {
                return .init(title: step.title, owner: step.owner == "lead" ? "Lead" : "You",
                             state: step.state == .done ? .done : (step.owner == "you" ? .needsYou : .waiting))
            }
            guard let uuid = UUID(uuidString: step.owner), let helper = records[AgentID(rawValue: uuid)],
                  helper.parentAgentID == id else {
                return .init(title: step.title, owner: "Helper unavailable", state: .waiting)
            }
            let model = helper.harness.flatMap { AgentModelCatalog.shared.displayName(for: helper.model, harness: $0) } ?? helper.model
            let status = derivedStreamStatus(for: helper.id)
            let state: LeadPlanPresentation.State
            if helper.helperWatchdogNeedsYou != nil || helper.declaredStatus?.needsYou != nil || status == .needsAttention {
                state = .needsYou
            } else if status == .working {
                state = .running
            } else if helper.latestTerminalEvent?.outcome == .failed || helper.latestTerminalEvent?.outcome == .runtimeError
                        || helper.lastReport?.report.checks.contains(where: { $0.result == .fail }) == true
                        || helper.lastReport?.report.commandEvidence?.contains(where: { $0.outcome == .observedFailed }) == true {
                state = .failed
            } else if status == .done || helper.latestTerminalEvent?.outcome == .succeeded {
                state = .done
            } else {
                state = .waiting
            }
            return .init(title: step.title, owner: "\(helper.humanDisplayName) · \(model)", state: state)
        }
        return LeadPlanPresentation(steps: steps, collapsed: lead.leadPlanCollapsed)
    }

    func addLeadPlanObserver(for id: AgentID, _ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        leadPlanObservers[token] = (id, observer)
        return token
    }
    func removeLeadPlanObserver(_ token: UUID) { leadPlanObservers[token] = nil }
    func notifyLeadPlanChanged(_ id: AgentID) {
        let parent = records[id]?.parentAgentID
        for (lead, observer) in leadPlanObservers.values where lead == id || lead == parent { observer() }
    }
}
