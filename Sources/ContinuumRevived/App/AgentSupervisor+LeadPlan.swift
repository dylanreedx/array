import ContinuumRevivedCore
import Foundation

struct LeadPlanPresentation: Equatable {
    enum State: String { case waiting = "Waiting", running = "Running", needsYou = "Needs you", failed = "Failed", done = "Done" }
    struct Step: Equatable {
        let title: String
        let owner: String
        let state: State
        /// Right-hand detail: how long ago a finished helper ended, or a lead-written
        /// row's age.
        var note: String? = nil
        /// A helper row: the dot says its status is observed, not written.
        var liveDot: Bool = false
        /// A group label, not a step ("Needs you", "Working", "Plan · 3d ago").
        var isSection: Bool = false
        /// Written by the lead long ago: drawn dimmed, section label in attention ink.
        var stale: Bool = false
        /// Clicking the owner reveals this helper's tile.
        var ownerAgent: AgentID? = nil
    }
    let steps: [Step]
    let collapsed: Bool
    /// The lead's own `needsYou` line, when it has a decision for Dylan.
    var decision: String? = nil
    /// Answers the lead offered with that decision (`array_status options`).
    var options: [String] = []
    /// Header text when the drawer is not just a plan ("Helpers · 1 working").
    var title: String? = nil

    private var rows: [Step] { steps.filter { !$0.isSection } }
    var summary: String {
        if let title { return title }
        return "Plan · \(rows.filter { $0.state == .done }.count) of \(rows.count) done"
    }
    var urgent: Step? {
        for state in [State.needsYou, .failed, .running] {
            if let step = rows.first(where: { $0.state == state }) { return step }
        }
        return nil
    }
    var header: String {
        guard collapsed else { return summary }
        if let decision { return summary + " · Needs you: \(decision)" }
        guard let urgent else { return summary }
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
            // "Plan first": a step for a helper not started yet ("helper A") is
            // kept as written and shown waiting until the lead names its ID.
            if matches.isEmpty, Self.isUnstartedHelperOwner(owner) { continue }
            guard matches.count == 1, let helper = matches.first else {
                return .failure(.init(code: .invalidRequest, message: "Plan owner must name one of your helpers (use its ID if names repeat). Nothing was recorded."))
            }
            resolved[i].owner = helper.id.rawValue.uuidString
        }
        return .success(resolved)
    }

    static func isUnstartedHelperOwner(_ owner: String) -> Bool {
        UUID(uuidString: owner) == nil && owner.lowercased().hasPrefix("helper")
    }

    /// A helper's state as Array observes it. The lead cannot write this.
    func liveLeadPlanState(of helper: AgentRecord) -> LeadPlanPresentation.State {
        let status = derivedStreamStatus(for: helper.id)
        if helper.helperWatchdogNeedsYou != nil || helper.declaredStatus?.needsYou != nil || status == .needsAttention {
            return .needsYou
        } else if status == .working {
            return .running
        } else if helper.latestTerminalEvent?.outcome == .failed || helper.latestTerminalEvent?.outcome == .runtimeError
                    || helper.lastReport?.report.checks.contains(where: { $0.result == .fail }) == true
                    || helper.lastReport?.report.commandEvidence?.contains(where: { $0.outcome == .observedFailed }) == true {
            return .failed
        } else if status == .done || helper.latestTerminalEvent?.outcome == .succeeded {
            return .done
        }
        return .waiting
    }

    /// "3d ago", "2h ago", "14 min ago"; nil under a minute.
    static func relativeAge(_ date: Date, now: Date) -> String? {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return nil }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    /// A plan older than this is drawn as stale.
    static let leadPlanStaleAfter: TimeInterval = 24 * 3600
    static let leadPlanRosterLimit = 6
    static let leadPlanDoneWindow: TimeInterval = 24 * 3600
    /// Helper activity repaints the drawer at most this often.
    static let leadPlanActivityCadence: TimeInterval = 0.25

    func leadPlan(for id: AgentID, now: Date = Date()) -> LeadPlanPresentation? {
        guard let lead = records[id], lead.mode == .managed, lead.parentAgentID == nil else { return nil }
        let declared = lead.declaredStatus
        let plan = declared?.plan ?? []
        let helpers = records.values.filter { $0.parentAgentID == id && $0.archivedAt == nil }
        let planned = Set(plan.compactMap { UUID(uuidString: $0.owner) })

        // Helpers the plan does not name: observed, so never stale. Needs-you and
        // failed first, then working, then what finished in the last day.
        var roster: [LeadPlanPresentation.Step] = []
        func rows(_ group: String, _ state: Set<LeadPlanPresentation.State>, limit: Int, recent: Bool = false) {
            var found: [(AgentRecord, LeadPlanPresentation.State)] = []
            for helper in helpers where !planned.contains(helper.id.rawValue) {
                let live = liveLeadPlanState(of: helper)
                guard state.contains(live) else { continue }
                if recent, now.timeIntervalSince(helper.latestTerminalEvent?.endedAt ?? helper.lastActivityAt) > Self.leadPlanDoneWindow { continue }
                found.append((helper, live))
            }
            found.sort { $0.0.lastActivityAt > $1.0.lastActivityAt }
            let room = max(0, min(limit, Self.leadPlanRosterLimit - roster.filter { !$0.isSection }.count))
            guard room > 0, !found.isEmpty else { return }
            roster.append(.init(title: group, owner: "", state: .waiting, isSection: true))
            for (helper, live) in found.prefix(room) {
                let model = helper.harness.flatMap { AgentModelCatalog.shared.displayName(for: helper.model, harness: $0) } ?? helper.model
                let ended = helper.latestTerminalEvent?.endedAt ?? helper.lastActivityAt
                // Its own status line says what it is doing; without one the title is
                // its name, which the owner cell must not repeat.
                let said = helper.declaredStatus?.now
                roster.append(.init(
                    title: said ?? helper.humanDisplayName,
                    owner: said == nil ? model : "\(helper.humanDisplayName) · \(model)", state: live,
                    note: live == .done || live == .failed ? Self.relativeAge(ended, now: now) : nil,
                    liveDot: true, ownerAgent: helper.id))
            }
        }
        rows("Needs you", [.needsYou, .failed], limit: 3)
        rows("Working", [.running], limit: 4)
        rows("Done", [.done], limit: 3, recent: true)

        var steps = roster
        if !plan.isEmpty {
            let wrote = declared?.planDeclaredAt ?? declared?.declaredAt
            let age = wrote.flatMap { Self.relativeAge($0, now: now) }
            let stale = wrote.map { now.timeIntervalSince($0) > Self.leadPlanStaleAfter } ?? false
            if !roster.isEmpty || stale {
                steps.append(.init(title: age.map { "Plan · written \($0)" } ?? "Plan", owner: "", state: .waiting,
                                   isSection: true, stale: stale))
            }
            for step in plan {
                if step.owner == "lead" || step.owner == "you" {
                    steps.append(.init(title: step.title, owner: step.owner == "lead" ? "Lead" : "You",
                                       state: step.state == .done ? .done : (step.owner == "you" ? .needsYou : .waiting),
                                       note: step.owner == "you" && step.state != .done && stale ? "asked \(age ?? "")" : nil, stale: stale))
                    continue
                }
                guard let uuid = UUID(uuidString: step.owner), let helper = records[AgentID(rawValue: uuid)],
                      helper.parentAgentID == id else {
                    if Self.isUnstartedHelperOwner(step.owner) {
                        steps.append(.init(title: step.title, owner: step.owner, state: .waiting,
                                           note: stale ? "never started" : nil, stale: stale))
                    } else {
                        steps.append(.init(title: step.title, owner: "Helper unavailable", state: .waiting, stale: stale))
                    }
                    continue
                }
                let model = helper.harness.flatMap { AgentModelCatalog.shared.displayName(for: helper.model, harness: $0) } ?? helper.model
                steps.append(.init(title: step.title, owner: "\(helper.humanDisplayName) · \(model)",
                                   state: liveLeadPlanState(of: helper), liveDot: true, stale: stale, ownerAgent: helper.id))
            }
        }
        let decision = declared?.needsYou
        guard !steps.isEmpty || decision != nil else { return nil }
        // A drawer that is only the lead's plan keeps "Plan · n of m done"; one
        // that shows observed helpers is headed by what they are doing.
        var title: String?
        if plan.isEmpty || !roster.isEmpty {
            let observed = steps.filter { !$0.isSection && $0.ownerAgent != nil }
            let working = observed.filter { $0.state == .running }.count
            let needs = observed.filter { $0.state == .needsYou || $0.state == .failed }.count + (decision == nil ? 0 : 1)
            var parts = ["Helpers"]
            if working > 0 { parts.append("\(working) working") }
            if needs > 0 { parts.append("\(needs) need you") }
            title = parts.joined(separator: " · ")
        }
        return LeadPlanPresentation(steps: steps, collapsed: lead.leadPlanCollapsed, decision: decision,
                                    options: decision == nil ? [] : (declared?.options ?? []), title: title)
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
