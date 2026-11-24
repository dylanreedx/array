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
        /// A failure that no longer needs the user (old, or the lead has since
        /// taken a turn). Still drawn as Failed; never urgent, never counted.
        var past: Bool = false
    }

    // MARK: The model (see ~/array-scratch/plan-drawer-redesign/MODEL.md)

    /// Where a helper sits. Header counts and groups both read this and nothing else.
    /// - working: a turn is running.
    /// - waiting: idle and alive (between turns).
    /// - needsYou: blocked/asked for the user, or FAILED recently and unacknowledged.
    /// - finished: done, or a failure that stopped counting.
    enum Bucket: String { case needsYou, working, waiting, finished }
    struct Helper: Equatable, Identifiable {
        let id: AgentID
        let name: String
        let model: String
        let state: State
        let bucket: Bucket
        /// "3d ago" for finished helpers.
        let note: String?
        /// When the helper's last turn ended (its failure or finish time), else
        /// its last activity. Raw date, so the view can phrase its own age.
        let endedAt: Date?
    }
    struct Entry: Equatable, Identifiable {
        enum OwnerKind: String { case lead, you, helpers, unstarted, unavailable }
        /// Stable across recomputes: the normalised title plus its occurrence index.
        let id: String
        let title: String
        let ownerKind: OwnerKind
        /// "Lead", "You", the raw "helper A" name, or "Helper unavailable".
        let ownerLabel: String
        let state: State
        let stale: Bool
        let note: String?
        /// Helpers that own this step, oldest first. Empty for lead/you steps.
        let helpers: [Helper]
    }
    struct Counts: Equatable {
        var working = 0, waiting = 0, needsYou = 0, finished = 0
    }
    /// Plan steps in plan order, each with its linked helpers.
    var entries: [Entry] = []
    /// Helpers linked to no step: working/needsYou/waiting by creation order, then recent finished.
    var tail: [Helper] = []
    var counts = Counts()
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
            if let step = rows.first(where: { $0.state == state && !$0.past }) { return step }
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
        } else if status == .working || status == .configuring {
            // A runner restarting inside a turn reads `.configuring` for a moment;
            // the helper is still at work, so its row must not drop out.
            return .running
        } else if helper.latestTerminalEvent?.outcome == .failed || helper.latestTerminalEvent?.outcome == .runtimeError
                    || helper.lastReport?.report.checks.contains(where: { $0.result == .fail }) == true
                    || helper.lastReport?.report.commandEvidence?.contains(where: { $0.outcome == .observedFailed }) == true {
            return .failed
        } else if status == .done || helper.latestTerminalEvent?.outcome == .succeeded {
            // A turn ending is not the helper being done: it may have ended
            // without its report, or left a background command running. Done
            // needs a report filed in or after its latest turn and nothing of
            // its own still alive; until then it is between turns, waiting.
            let reported = helper.lastReport.map { $0.filedAt >= (helper.latestTurnAt ?? .distantPast) } ?? false
            return reported && idleWaitingFact(for: helper.id, now: Date()) == nil ? .done : .waiting
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

    /// A failed helper needs the user only while it is recent (under a day) AND the
    /// lead has not completed a turn since it failed (the lead has had its chance
    /// to act on it). Otherwise it is past: Failed, but finished, not "needs you".
    static let leadFailureNeedsYouWindow: TimeInterval = 24 * 3600

    func leadPlanBucket(of helper: AgentRecord, state: LeadPlanPresentation.State, lead: AgentRecord, now: Date) -> LeadPlanPresentation.Bucket {
        switch state {
        case .needsYou: return .needsYou
        case .running: return .working
        case .waiting: return .waiting
        case .done: return .finished
        case .failed:
            let ended = helper.latestTerminalEvent?.endedAt ?? helper.lastActivityAt
            if now.timeIntervalSince(ended) > Self.leadFailureNeedsYouWindow { return .finished }
            if let handled = lead.latestTerminalEvent?.endedAt, handled > ended { return .finished }
            return .needsYou
        }
    }

    private func leadPlanHelper(_ helper: AgentRecord, lead: AgentRecord, now: Date) -> LeadPlanPresentation.Helper {
        let state = liveLeadPlanState(of: helper)
        let bucket = leadPlanBucket(of: helper, state: state, lead: lead, now: now)
        let model = helper.harness.flatMap { AgentModelCatalog.shared.displayName(for: helper.model, harness: $0) } ?? helper.model
        let ended = helper.latestTerminalEvent?.endedAt ?? helper.lastActivityAt
        return .init(id: helper.id, name: helper.humanDisplayName, model: model, state: state, bucket: bucket,
                     note: bucket == .finished || state == .failed ? Self.relativeAge(ended, now: now) : nil,
                     endedAt: ended)
    }

    /// Helpers of this lead a plan owner names: by ID, else by name (names may repeat).
    private func leadPlanLinked(_ owner: String, among helpers: [AgentRecord]) -> [AgentRecord] {
        let key = owner.trimmingCharacters(in: .whitespaces)
        return helpers.filter {
            $0.id.rawValue.uuidString.caseInsensitiveCompare(key) == .orderedSame
                || $0.humanDisplayName.caseInsensitiveCompare(key) == .orderedSame
        }
    }

    func leadPlan(for id: AgentID, now: Date = Date()) -> LeadPlanPresentation? {
        guard let lead = records[id], lead.mode == .managed, lead.parentAgentID == nil else { return nil }
        let declared = lead.declaredStatus
        let plan = declared?.plan ?? []
        // Creation order, never activity: activity stamps move on every event.
        let helpers = records.values.filter { $0.parentAgentID == id && $0.archivedAt == nil }
            .sorted { ($0.createdAt, $0.id.rawValue.uuidString) < ($1.createdAt, $1.id.rawValue.uuidString) }
        let wrote = declared?.planDeclaredAt ?? declared?.declaredAt
        let age = wrote.flatMap { Self.relativeAge($0, now: now) }
        let stale = wrote.map { now.timeIntervalSince($0) > Self.leadPlanStaleAfter } ?? false

        // 1. Plan steps in plan order, each with the helpers that own it.
        var linkedIDs = Set<AgentID>()
        var seen: [String: Int] = [:]
        var entries: [LeadPlanPresentation.Entry] = []
        for step in plan {
            let norm = step.title.lowercased()
            let n = seen[norm, default: 0]; seen[norm] = n + 1
            let entryID = "\(norm)#\(n)"
            if step.owner == "lead" || step.owner == "you" {
                let you = step.owner == "you"
                entries.append(.init(id: entryID, title: step.title, ownerKind: you ? .you : .lead, ownerLabel: you ? "You" : "Lead",
                    state: step.state == .done ? .done : (you ? .needsYou : .waiting), stale: stale,
                    note: you && step.state != .done && stale ? "asked \(age ?? "")" : nil, helpers: []))
                continue
            }
            let linked = leadPlanLinked(step.owner, among: helpers).map { leadPlanHelper($0, lead: lead, now: now) }
            for h in linked { linkedIDs.insert(h.id) }
            guard !linked.isEmpty else {
                let unstarted = Self.isUnstartedHelperOwner(step.owner)
                entries.append(.init(id: entryID, title: step.title, ownerKind: unstarted ? .unstarted : .unavailable,
                    ownerLabel: unstarted ? step.owner : "Helper unavailable", state: .waiting, stale: stale,
                    note: unstarted && stale ? "never started" : nil, helpers: []))
                continue
            }
            // The step reads as its most pressing helper: attention, working, waiting, then finished.
            let lead1 = linked.first { $0.bucket == .needsYou } ?? linked.first { $0.bucket == .working }
                ?? linked.first { $0.bucket == .waiting } ?? linked.first { $0.state == .failed } ?? linked[0]
            entries.append(.init(id: entryID, title: step.title, ownerKind: .helpers, ownerLabel: linked.map(\.name).joined(separator: ", "),
                state: lead1.state, stale: stale, note: nil, helpers: linked))
        }

        // 2. Helpers no step names: observed, never stale.
        func finishedAt(_ hid: AgentID) -> Date { records[hid].map { $0.latestTerminalEvent?.endedAt ?? $0.lastActivityAt } ?? .distantPast }
        let allHelpers = helpers.map { leadPlanHelper($0, lead: lead, now: now) }
        var counts = LeadPlanPresentation.Counts()
        for h in allHelpers where h.bucket != .finished || now.timeIntervalSince(finishedAt(h.id)) <= Self.leadPlanDoneWindow {
            switch h.bucket {
            case .needsYou: counts.needsYou += 1
            case .working: counts.working += 1
            case .waiting: counts.waiting += 1
            case .finished: counts.finished += 1
            }
        }
        let unplanned = allHelpers.filter { !linkedIDs.contains($0.id) }
        let order: [LeadPlanPresentation.Bucket] = [.needsYou, .working, .waiting, .finished]
        var tail: [LeadPlanPresentation.Helper] = []
        for bucket in order {
            tail += unplanned.filter { $0.bucket == bucket
                && (bucket != .finished || now.timeIntervalSince(finishedAt($0.id)) <= Self.leadPlanDoneWindow) }
        }

        // 3. Legacy flat rows for the current drawer view: bounded, grouped by bucket.
        var roster: [LeadPlanPresentation.Step] = []
        func group(_ title: String, _ bucket: LeadPlanPresentation.Bucket, limit: Int) {
            let found = tail.filter { $0.bucket == bucket }
            let room = max(0, min(limit, Self.leadPlanRosterLimit - roster.filter { !$0.isSection }.count))
            guard room > 0, !found.isEmpty else { return }
            let title = bucket == .finished && found.contains(where: { $0.state == .failed }) ? "Finished" : title
            roster.append(.init(title: title, owner: "", state: .waiting, isSection: true))
            for h in found.prefix(room) {
                // One kind per column, fixed by the row and never by its state: the
                // title is the helper's name, the owner is its model.
                roster.append(.init(title: h.name, owner: h.model, state: h.state, note: h.state == .done || h.state == .failed ? h.note : nil,
                                    liveDot: true, ownerAgent: h.id, past: h.state == .failed && h.bucket == .finished))
            }
        }
        group("Needs you", .needsYou, limit: 3)
        group("Working", .working, limit: 4)
        group("Waiting", .waiting, limit: 4)
        group("Done", .finished, limit: 3)

        var steps = roster
        if !plan.isEmpty {
            if !roster.isEmpty || stale {
                steps.append(.init(title: age.map { "Plan · written \($0)" } ?? "Plan", owner: "", state: .waiting,
                                   isSection: true, stale: stale))
            }
            for e in entries {
                switch e.ownerKind {
                case .lead, .you, .unstarted, .unavailable:
                    steps.append(.init(title: e.title, owner: e.ownerLabel, state: e.state, note: e.note, stale: e.stale))
                case .helpers:
                    let first = e.helpers.first { $0.state == e.state } ?? e.helpers[0]
                    let owner = e.helpers.count == 1 ? "\(first.name) · \(first.model)" : e.ownerLabel
                    steps.append(.init(title: e.title, owner: owner, state: e.state, liveDot: true, stale: e.stale,
                                       ownerAgent: first.id, past: first.state == .failed && first.bucket == .finished))
                }
            }
        }
        let decision = declared?.needsYou
        guard !steps.isEmpty || decision != nil else { return nil }
        var title: String?
        if plan.isEmpty || !roster.isEmpty {
            var parts = ["Helpers"]
            if counts.working > 0 { parts.append("\(counts.working) working") }
            if counts.waiting > 0 { parts.append("\(counts.waiting) waiting") }
            let needs = counts.needsYou + (decision == nil ? 0 : 1)
            if needs > 0 { parts.append("\(needs) need you") }
            title = parts.joined(separator: " · ")
        }
        var out = LeadPlanPresentation(steps: steps, collapsed: lead.leadPlanCollapsed, decision: decision,
                                       options: decision == nil ? [] : (declared?.options ?? []), title: title)
        out.entries = entries; out.tail = tail; out.counts = counts
        return out
    }

    func addLeadPlanObserver(for id: AgentID, _ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        leadPlanObservers[token] = (id, observer)
        return token
    }
    func removeLeadPlanObserver(_ token: UUID) { leadPlanObservers[token] = nil }
    /// Helper stream events arrive per token. They mark the drawer dirty and it
    /// repaints once per `leadPlanActivityCadence`, not once per event; status,
    /// reports and watchdog changes still repaint at once.
    func noteLeadPlanActivity(_ id: AgentID) {
        let wasIdle = leadPlanActivityPending.isEmpty
        leadPlanActivityPending.insert(id)
        if let parent = records[id]?.parentAgentID { leadPlanActivityPending.insert(parent) }
        guard wasIdle else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.leadPlanActivityCadence))
            guard let self else { return }
            let targets = self.leadPlanActivityPending
            self.leadPlanActivityPending = []
            for (lead, observer) in self.leadPlanObservers.values where targets.contains(lead) { observer() }
        }
    }
    func notifyLeadPlanChanged(_ id: AgentID) {
        let parent = records[id]?.parentAgentID
        for (lead, observer) in leadPlanObservers.values where lead == id || lead == parent { observer() }
    }
}
