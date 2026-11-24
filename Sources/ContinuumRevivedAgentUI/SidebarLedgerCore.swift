import Foundation

// Sidebar round (array/sidebar-next). The shared core both sidebar layouts
// read: one reconciled count per lead, one failure cause with one action, the
// Clear plan, and the incident list. PURE: rows in, values out. Every number a
// row, a fold line, the quick status and accessibility say comes from here, so
// they cannot disagree (the "16 more, 1 failed" on a row of 18 was two
// functions counting two populations).

/// The sidebar's layout. Two styles over one core; the default is the only
/// thing that flips when one is picked.
public enum SidebarLayout: String, CaseIterable, Equatable, Sendable {
    case ledger
    case quietInbox

    public static let defaultsKey = "continuum.sidebar.layout"
    public static let defaultLayout: SidebarLayout = .quietInbox

    public var title: String {
        switch self {
        case .ledger: return "Ledger"
        case .quietInbox: return "Quiet inbox"
        }
    }

    public static func resolve(in defaults: UserDefaults) -> SidebarLayout {
        defaults.string(forKey: defaultsKey).flatMap(SidebarLayout.init(rawValue:)) ?? defaultLayout
    }
}

/// Why a turn ended badly, in the classes a person can act on. Presentation
/// only: classified from the words and outcome Array already records.
public enum SidebarFailureCause: String, CaseIterable, Equatable, Sendable {
    case usageLimit
    case providerBusy
    case signInExpired
    case couldNotStart
    case interruptedByRestart
    case taskError

    /// Blocking causes stay in front of you and are never cleared: the work
    /// cannot continue until you act.
    public var isBlocking: Bool {
        switch self {
        // A usage pause needs nobody: Array resumes it at the reset. It is
        // never a Needs-you item (usage-resume, step 8).
        case .signInExpired, .couldNotStart: return true
        case .usageLimit, .providerBusy, .interruptedByRestart, .taskError: return false
        }
    }

    /// One word for a lead's status column, the tally's word for the state;
    /// the long cause lives on the card's cause line.
    public var shortLabel: String {
        switch self {
        case .usageLimit: return "Paused"
        case .interruptedByRestart: return "Interrupted"
        case .providerBusy, .signInExpired, .couldNotStart, .taskError: return "Failed"
        }
    }

    /// The row's word. A usage stop is a pause, never "Failed".
    public func label(harness: String?) -> String {
        switch self {
        case .usageLimit: return "Paused · usage"
        case .providerBusy: return "\(SidebarRecovery.providerName(harness)) was busy"
        case .signInExpired: return "Sign-in expired"
        case .couldNotStart: return "Couldn't start"
        case .interruptedByRestart: return "Interrupted by restart"
        case .taskError: return "Failed"
        }
    }

    /// The one action. Sign-in runs the CLI's own login; never an API key.
    public var actionTitle: String {
        switch self {
        // Switching accounts lives in the agent's tile only: the sidebar opens it.
        case .usageLimit: return "Open"
        case .providerBusy: return "Retry"
        case .signInExpired: return "Sign in…"
        case .couldNotStart: return "Repair setup…"
        case .interruptedByRestart: return "Resume"
        case .taskError: return "Open"
        }
    }

    public var symbol: String {
        switch self {
        case .usageLimit: return "pause.circle"
        case .providerBusy: return "exclamationmark.triangle"
        case .signInExpired: return "exclamationmark.triangle"
        case .couldNotStart: return "exclamationmark.triangle"
        case .interruptedByRestart: return "clock"
        case .taskError: return "exclamationmark.triangle"
        }
    }
}

/// Exactly one of these per helper: the states partition every count.
public enum SidebarTallyState: String, CaseIterable, Equatable, Sendable {
    case working
    case needsYou
    case paused
    case failed
    case stopped
    case done

    public func phrase(_ count: Int) -> String {
        switch self {
        case .working: return "\(count) working"
        case .needsYou: return count == 1 ? "1 needs you" : "\(count) need you"
        case .paused: return "\(count) paused"
        case .failed: return "\(count) failed"
        // One word for the state on every surface: a helper whose turn was cut
        // off (a restart, a cancel) is "interrupted", never "stopped" or "failed".
        case .stopped: return "\(count) interrupted"
        case .done: return "\(count) done"
        }
    }

    public var symbol: String {
        switch self {
        case .working: return "arrow.triangle.2.circlepath"
        case .needsYou: return "questionmark.circle"
        case .paused: return "pause.circle"
        case .failed: return "exclamationmark.triangle"
        case .stopped: return "stop.circle"
        case .done: return "checkmark.circle"
        }
    }
}

public enum SidebarRecovery {
    public static func providerName(_ harness: String?) -> String {
        // Records carry the harness's display name ("Claude Code", "Codex",
        // "Pi") or its raw value; match either.
        let name = harness?.lowercased() ?? ""
        if name.contains("claude") { return "Claude" }
        if name.contains("codex") { return "Codex" }
        if name == "pi" || name.hasPrefix("pi ") { return "Pi" }
        return "The provider"
    }

    /// Classify recorded failure words. nil when the words name no class: the
    /// caller then decides from the outcome alone.
    public static func classify(_ detail: String?) -> SidebarFailureCause? {
        guard let detail, !detail.isEmpty else { return nil }
        let text = detail.lowercased()
        func has(_ markers: [String]) -> Bool { markers.contains(where: text.contains) }
        // The CLIs' own words (failure census), not topic words: a task error
        // that merely mentions a file, a login or a quota must stay Failed, or
        // Clear would refuse it as a blocker.
        if has(["hit your usage limit", "usage limit reached", "rate_limit", "rate limit reached",
                "rate limit exceeded", "5-hour limit", "weekly limit", "session limit", "hit your limit",
                "out of usage", "insufficient_quota", "quota exceeded", "credit balance is too low"]) {
            return .usageLimit
        }
        if has(["failed to authenticate", "authentication_error", "authentication failed",
                "oauth session expired", "oauth token has expired", "invalid api key",
                "please run /login", "not logged in", "token has expired", "sign in again"]) {
            return .signInExpired
        }
        if has(["could not start:", "could not launch", "couldn't start:", "failed to launch"]) {
            return .couldNotStart
        }
        if has(["overloaded", "serveroverloaded", "at capacity", "server is busy", " 529", " 503",
                "temporarily unavailable"]) { return .providerBusy }
        if has(["array restarted", "previous session"]) {
            return .interruptedByRestart
        }
        return nil
    }

    /// The row's recovery cause, or nil when its last turn needs no recovery.
    public static func cause(for row: AgentInboxRow) -> SidebarFailureCause? {
        switch row.state {
        case .working, .approval, .input: return nil
        case .failed, .ready: break
        }
        let outcome = row.terminalEvent?.outcome
        let failed = row.state == .failed || outcome == .failed || outcome == .runtimeError
        if failed {
            let cause = classify(row.failureDetail) ?? .taskError
            // A usage stop is a pause only while the CLI's live usage is still
            // exhausted. Once usage is back (or nothing live says it is out),
            // the old stop is an ordinary failed turn: its own words, clearable.
            if cause == .usageLimit, !row.usageExhaustedNow { return .taskError }
            return cause
        }
        if outcome == .interrupted {
            let words = classify(row.failureDetail)
            if words == .interruptedByRestart { return .interruptedByRestart }
            // Array delivers a usage stop as an interrupted turn carrying the
            // CLI's line; it is a pause only while the agent's own pause lasts.
            if words == .usageLimit, row.usageExhaustedNow { return .usageLimit }
        }
        return nil
    }

    /// The one state this row is counted in.
    public static func state(for row: AgentInboxRow) -> SidebarTallyState {
        switch row.state {
        case .working: return .working
        case .approval, .input: return .needsYou
        case .failed, .ready: break
        }
        if let cause = cause(for: row) {
            switch cause {
            case .usageLimit: return .paused
            case .interruptedByRestart: return .stopped
            case .providerBusy, .signInExpired, .couldNotStart, .taskError: return .failed
            }
        }
        // A helper whose report failed a check, or that asked for you, needs you
        // however its turn ended: the lead's helper drawer says the same.
        if row.parentId != nil, row.selfReport?.reportedFailure == true || row.selfReport?.needsYou != nil {
            return .needsYou
        }
        switch row.terminalEvent?.outcome {
        case .interrupted?, .cancelled?: return .stopped
        default: return .done
        }
    }

    /// The action as this row reads it: a mirrored helper recovers through its
    /// lead, so its resume reads "Resume with lead".
    public static func actionTitle(for row: AgentInboxRow, cause: SidebarFailureCause) -> String {
        if row.resumesThroughLead, cause == .interruptedByRestart || cause == .providerBusy {
            return "Resume with lead"
        }
        return cause.actionTitle
    }

    /// A short reason for a real task error: the first line of the recorded
    /// words, bounded. nil when nothing was recorded.
    public static func shortReason(_ row: AgentInboxRow, maxCharacters: Int = 60) -> String? {
        guard let line = row.failureDetail?
            .split(whereSeparator: \.isNewline).first
            .map({ $0.trimmingCharacters(in: .whitespaces) }), !line.isEmpty else { return nil }
        return line.count > maxCharacters ? String(line.prefix(maxCharacters - 1)) + "…" : line
    }
}

/// One reconciled count per lead.
///
/// Total = unique descendants under the lead, sub-leads' helpers included, the
/// lead excluded. The six states partition it exactly; shown + folded = total.
public struct SidebarLeadTally: Equatable, Sendable {
    public let leadId: UUID
    public let memberIDs: [UUID]
    public let counts: [SidebarTallyState: Int]
    public let shown: Int
    public let folded: Int
    /// Folded members per state, so the fold line can say what it holds.
    public let foldedCounts: [SidebarTallyState: Int]

    public var total: Int { memberIDs.count }

    public func count(_ state: SidebarTallyState) -> Int { counts[state] ?? 0 }

    /// The chip: "18 helpers · 12 paused · 1 failed". The states that want you
    /// or are moving; zero subsets omitted. Failure is said here and only here.
    public var countLine: String {
        var parts = [total == 1 ? "1 helper" : "\(total) helpers"]
        for state in [SidebarTallyState.working, .needsYou, .paused, .failed, .stopped] where count(state) > 0 {
            parts.append(state.phrase(count(state)))
        }
        return parts.joined(separator: " · ")
    }

    /// The quiet inbox's summary line under a lead: what is live or wants you
    /// first ("3 working · 1 needs you · 14 failed · 4 interrupted"), never the
    /// lifetime total, which grows with every helper a long lead ever ran and
    /// says nothing about now. Only when nothing is live or unresolved does it
    /// name the total, as the one fact left ("All 182 helpers done").
    public var liveLine: String {
        // A failed helper needs you: it is said as the lead's helper drawer says
        // it, in the same words and count, never as done.
        var parts: [String] = []
        if count(.working) > 0 { parts.append(SidebarTallyState.working.phrase(count(.working))) }
        let needs = count(.needsYou) + count(.failed)
        if needs > 0 { parts.append(SidebarTallyState.needsYou.phrase(needs)) }
        for state in [SidebarTallyState.paused, .stopped] where count(state) > 0 {
            parts.append(state.phrase(count(state)))
        }
        guard parts.isEmpty else { return parts.joined(separator: " · ") }
        return total == 1 ? "1 helper, done" : "All \(total) helpers done"
    }

    /// Every state, for the tooltip and VoiceOver: the full partition.
    public var fullLine: String {
        var parts = [total == 1 ? "1 helper" : "\(total) helpers"]
        for state in SidebarTallyState.allCases where count(state) > 0 {
            parts.append(state.phrase(count(state)))
        }
        return parts.joined(separator: " · ")
    }

    /// The fold: "5 folded · includes 3 stopped". It names only what the chip
    /// does not, so a failure is never said twice on one card.
    public var foldLine: String { "\(folded) more" }

    public var accessibilityLabel: String {
        "\(fullLine). \(shown) shown, \(folded) hidden."
    }

    /// Partition proof, for witnesses: states sum to total, shown + folded too.
    public var reconciles: Bool {
        counts.values.reduce(0, +) == total && shown + folded == total
            && foldedCounts.values.reduce(0, +) == folded
    }

    public static func tally(
        leadId: UUID, rows: [AgentInboxRow], shownIDs: Set<UUID>
    ) -> SidebarLeadTally {
        var childrenOf: [UUID: [AgentInboxRow]] = [:]
        for row in rows {
            if let parent = row.parentId, parent != row.id { childrenOf[parent, default: []].append(row) }
        }
        var seen: Set<UUID> = [leadId]
        var members: [AgentInboxRow] = []
        var stack = (childrenOf[leadId] ?? []).reversed().map { $0 }
        while let row = stack.popLast() {
            guard seen.insert(row.id).inserted else { continue }
            members.append(row)
            stack.append(contentsOf: (childrenOf[row.id] ?? []).reversed())
        }
        var counts: [SidebarTallyState: Int] = [:]
        var foldedCounts: [SidebarTallyState: Int] = [:]
        var shown = 0
        for row in members {
            let state = SidebarRecovery.state(for: row)
            counts[state, default: 0] += 1
            if shownIDs.contains(row.id) { shown += 1 } else { foldedCounts[state, default: 0] += 1 }
        }
        return SidebarLeadTally(
            leadId: leadId, memberIDs: members.map(\.id), counts: counts,
            shown: shown, folded: members.count - shown, foldedCounts: foldedCounts)
    }
}

/// One line of the "For you" list: one incident, one action.
public struct SidebarIncident: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case needsYou
        case cause(SidebarFailureCause)
    }

    public let id: String
    public let kind: Kind
    public let symbol: String
    public let title: String
    public let detail: String
    public let actionTitle: String
    /// Every agent the incident is about.
    public let agentIDs: [UUID]
    /// The agents that can actually resume: owners, not records. A mirrored
    /// helper counts through its lead, once.
    public let ownerIDs: [UUID]
    /// Distinct top-level families touched.
    public let familyIDs: [UUID]
    public let harness: String?

    /// Blocking incidents sit under "For you" and are never cleared; the rest
    /// are updates, grouped by cause, and Clear acknowledges them.
    public var isBlocking: Bool {
        switch kind {
        case .needsYou: return true
        case .cause(let cause): return cause.isBlocking
        }
    }
}

public enum SidebarIncidents {
    /// Asking agents listed one per line before the rest share a line.
    public static let maxAsksShown = 3

    /// The incidents in the live rows, blocking first. `rows` are the rows the
    /// list draws from (already scoped), including folded helpers.
    public static func build(rows: [AgentInboxRow]) -> [SidebarIncident] {
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func family(of row: AgentInboxRow) -> AgentInboxRow {
            var current = row
            var seen: Set<UUID> = [row.id]
            while let parent = current.parentId.flatMap({ byId[$0] }), seen.insert(parent.id).inserted {
                current = parent
            }
            return current
        }
        func owner(of row: AgentInboxRow) -> UUID {
            guard row.resumesThroughLead else { return row.id }
            var current = row
            var seen: Set<UUID> = [row.id]
            while current.resumesThroughLead, let parent = current.parentId.flatMap({ byId[$0] }),
                  seen.insert(parent.id).inserted {
                current = parent
            }
            return current.id
        }
        func unique(_ ids: [UUID]) -> [UUID] {
            var seen: Set<UUID> = []
            return ids.filter { seen.insert($0).inserted }
        }
        let live = rows.filter { $0.lifecycle == .active && !$0.isCleared }
        var result: [SidebarIncident] = []

        // Needs you: one per asking agent, attributed to its family; past
        // `maxAsksShown`, the rest share one line so the list stays short.
        let asking = live.filter { $0.state == .approval || $0.state == .input }
        for row in asking.prefix(asking.count > maxAsksShown ? maxAsksShown - 1 : maxAsksShown) {
            let lead = family(of: row)
            result.append(SidebarIncident(
                id: "needs:\(row.id.uuidString)", kind: .needsYou, symbol: "questionmark.circle",
                title: row.displayTitle,
                detail: lead.id == row.id ? "Needs you" : "\(lead.displayTitle) · needs you",
                actionTitle: "Respond", agentIDs: [row.id], ownerIDs: [row.id],
                familyIDs: [lead.id], harness: row.harness))
        }
        if asking.count > maxAsksShown {
            let rest = Array(asking.dropFirst(maxAsksShown - 1))
            result.append(SidebarIncident(
                id: "needs:more", kind: .needsYou, symbol: "questionmark.circle",
                title: "\(rest.count) more need you", detail: rest.prefix(3).map(\.displayTitle).joined(separator: " · "),
                actionTitle: "Respond", agentIDs: rest.map(\.id), ownerIDs: rest.map(\.id),
                familyIDs: unique(rest.map { family(of: $0).id }), harness: nil))
        }

        // Causes: one incident per cause and provider.
        var grouped: [String: (cause: SidebarFailureCause, harness: String?, rows: [AgentInboxRow])] = [:]
        var order: [String] = []
        for row in live {
            guard let cause = SidebarRecovery.cause(for: row) else { continue }
            // Causes whose words name the CLI are grouped per CLI; the rest once.
            let perCLI: Bool
            switch cause {
            case .usageLimit, .signInExpired, .couldNotStart, .providerBusy: perCLI = true
            case .interruptedByRestart, .taskError: perCLI = false
            }
            let key = perCLI ? "\(cause.rawValue):\(SidebarRecovery.providerName(row.harness))" : cause.rawValue
            if grouped[key] == nil { grouped[key] = (cause, row.harness, []); order.append(key) }
            grouped[key]?.rows.append(row)
        }
        let causeOrder = SidebarFailureCause.allCases
        order.sort { lhs, rhs in
            let l = grouped[lhs]!, r = grouped[rhs]!
            let li = causeOrder.firstIndex(of: l.cause)!, ri = causeOrder.firstIndex(of: r.cause)!
            return li != ri ? li < ri : lhs < rhs
        }
        for key in order {
            let group = grouped[key]!
            let families = unique(group.rows.map { family(of: $0).id })
            let owners = unique(group.rows.map(owner(of:)))
            let provider = SidebarRecovery.providerName(group.harness)
            let count = group.rows.count
            let agents = count == 1 ? "1 agent" : "\(count) agents"
            let familyWord = families.count == 1 ? "1 family" : "\(families.count) families"
            let title: String
            let detail: String
            let first = group.rows[0]
            let firstFamily = family(of: first)
            let where1 = firstFamily.id == first.id ? first.displayTitle
                : "\(first.displayTitle) · \(firstFamily.displayTitle)"
            switch group.cause {
            case .usageLimit:
                title = "Waiting for \(provider) usage"
                detail = "\(agents) in \(familyWord) · Array resumes \(count == 1 ? "it" : "them") at the reset"
            case .signInExpired:
                title = "\(provider) sign-in expired"
                detail = count == 1 ? where1 : "\(agents) in \(familyWord)"
            case .couldNotStart:
                title = "\(provider) couldn't start"
                detail = count == 1 ? where1 : "\(agents) in \(familyWord)"
            case .providerBusy:
                title = "\(provider) was busy"
                detail = count == 1 ? where1 : "\(agents) in \(familyWord)"
            case .interruptedByRestart:
                title = count == 1 ? "Interrupted by restart" : "\(count) interrupted by restart"
                detail = count == 1 ? where1 : "\(familyWord)"
            case .taskError:
                title = count == 1 ? "Failed" : "\(count) failed"
                detail = count == 1
                    ? [SidebarRecovery.shortReason(first), where1].compactMap { $0 }.joined(separator: " · ")
                    : "\(familyWord)"
            }
            let action: String = {
                if group.cause == .interruptedByRestart || group.cause == .providerBusy,
                   group.rows.allSatisfy(\.resumesThroughLead) { return "Resume with lead" }
                return group.cause.actionTitle
            }()
            result.append(SidebarIncident(
                id: "cause:\(key)", kind: .cause(group.cause), symbol: group.cause.symbol,
                title: title, detail: detail, actionTitle: action,
                agentIDs: group.rows.map(\.id), ownerIDs: owners, familyIDs: families,
                harness: group.harness))
        }
        return result.filter(\.isBlocking) + result.filter { !$0.isBlocking }
    }
}

/// What Clear may acknowledge in the sidebar. Marks persist, Undo removes
/// them, and new activity releases them; agent lifecycle and tiles stay intact.
public enum SidebarClear {
    public enum Refusal: String, Equatable, Sendable {
        case working, needsYou, pausedOnUsage, blockingFailure, standing, blocked, alreadyParked
    }

    /// Why this row cannot be cleared, or nil when it can.
    public static func refusal(
        for row: AgentInboxRow, standing: Set<UUID>
    ) -> Refusal? {
        if standing.contains(row.id) { return .standing }
        if row.lifecycle != .active || row.isCleared { return .alreadyParked }
        switch SidebarRecovery.state(for: row) {
        case .working: return .working
        case .needsYou: return .needsYou
        case .paused: return .pausedOnUsage
        case .failed, .stopped, .done: break
        }
        if let cause = SidebarRecovery.cause(for: row), cause.isBlocking { return .blockingFailure }
        if row.settlementBlocked { return .blocked }
        return nil
    }

    /// The ids Clear N acts on, in list order. A lead whose family still holds
    /// anything that refuses is not cleared itself (that would carry blocked
    /// helpers into History); its clearable helpers still are.
    public static func eligibleIDs(
        rows: [AgentInboxRow], standing: Set<UUID>
    ) -> [UUID] {
        var childrenOf: [UUID: [AgentInboxRow]] = [:]
        for row in rows {
            if let parent = row.parentId, parent != row.id { childrenOf[parent, default: []].append(row) }
        }
        func subtreeClear(_ row: AgentInboxRow, seen: inout Set<UUID>) -> Bool {
            guard seen.insert(row.id).inserted else { return true }
            var ok = refusal(for: row, standing: standing) == nil
            for child in childrenOf[row.id] ?? [] {
                // A child already cleared is fine; anything else must be clearable.
                if child.isCleared { continue }
                if !subtreeClear(child, seen: &seen) { ok = false }
            }
            return ok
        }
        let candidates = rows.compactMap { row -> UUID? in
            guard refusal(for: row, standing: standing) == nil else { return nil }
            if childrenOf[row.id] != nil {
                var seen: Set<UUID> = []
                guard subtreeClear(row, seen: &seen) else { return nil }
            }
            return row.id
        }
        // A cleared lead takes its family with it; its helpers are not counted
        // again, so "Clear N" names the rows that leave.
        let candidateSet = Set(candidates)
        let parentOf = Dictionary(rows.compactMap { row in row.parentId.map { (row.id, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        func subsumed(_ id: UUID) -> Bool {
            var seen: Set<UUID> = [id]
            var current = parentOf[id]
            while let parent = current, seen.insert(parent).inserted {
                if candidateSet.contains(parent) { return true }
                current = parentOf[parent]
            }
            return false
        }
        return candidates.filter { !subsumed($0) }
    }
}

/// Standing leads: pinned at the top by the user, persisted per agent.
public enum SidebarStandingLeads {
    public static let defaultsKey = "continuum.sidebar.standingLeads"

    public static func load(from defaults: UserDefaults) -> Set<UUID> {
        Set((defaults.stringArray(forKey: defaultsKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    public static func save(_ ids: Set<UUID>, to defaults: UserDefaults) {
        defaults.set(ids.map(\.uuidString).sorted(), forKey: defaultsKey)
    }

    /// A standing home survives automatic settlement. Explicit snooze and
    /// archive still win; no lifecycle is written back to the agent store.
    public static func apply(_ ids: Set<UUID>, to rows: [AgentInboxRow]) -> [AgentInboxRow] {
        let roots = Set(rows.filter { row in
            guard row.parentId == nil, ids.contains(row.id) else { return false }
            switch row.lifecycle {
            case .active, .settled: return true
            case .archived, .snoozed: return false
            }
        }.map(\.id))
        let parentOf = Dictionary(rows.compactMap { row in row.parentId.map { (row.id, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        return rows.map { row in
            var top = row.id
            var seen: Set<UUID> = [top]
            while let parent = parentOf[top], seen.insert(parent).inserted { top = parent }
            guard roots.contains(top) else { return row }
            var result = row
            if row.id == top { result.isStanding = true }
            if case .settled = row.lifecycle {
                result = result.followingParent(lifecycle: .active, closingSince: row.closingSince,
                    workspaceName: row.workspaceName, workspaceId: row.workspaceId)
            }
            return result
        }
    }
}

/// Clear's record: an acknowledgement in the sidebar only. It moves no agent
/// lifecycle, closes no tile and settles nothing; it hides an outcome the user
/// has seen. A mark holds while the agent does nothing new: a newer terminal
/// event, newer activity, work or a raised hand releases it.
public struct SidebarClearMark: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let activityAt: Date
    public let clearedAt: Date

    public init(sequence: UInt64, activityAt: Date, clearedAt: Date) {
        self.sequence = sequence
        self.activityAt = activityAt
        self.clearedAt = clearedAt
    }
}

public enum SidebarClearMarks {
    public static let defaultsKey = "continuum.sidebar.clearedOutcomes"
    /// Slack for an activity stamp re-derived at the same instant.
    static let activitySlack: TimeInterval = 1

    public static func mark(for row: AgentInboxRow, now: Date) -> SidebarClearMark {
        SidebarClearMark(sequence: row.terminalEvent?.sequence ?? 0,
                         activityAt: row.lastActiveAt ?? row.terminalEvent?.endedAt ?? row.createdAt,
                         clearedAt: now)
    }

    /// Whether the mark still hides this row.
    public static func holds(_ mark: SidebarClearMark, for row: AgentInboxRow) -> Bool {
        switch row.state {
        case .working, .approval, .input: return false
        case .failed, .ready: break
        }
        // Details can arrive lazily for this same terminal event. A newly
        // discovered blocker is never hidden behind an old acknowledgement.
        // A usage stop is not one: it blocks only while usage is out live.
        let cause = SidebarRecovery.cause(for: row)
        if row.settlementBlocked || (cause?.isBlocking == true && cause != .usageLimit) { return false }
        if (row.terminalEvent?.sequence ?? 0) > mark.sequence { return false }
        let activity = row.lastActiveAt ?? row.terminalEvent?.endedAt ?? row.createdAt
        return activity <= mark.activityAt.addingTimeInterval(activitySlack)
    }

    public static func load(from defaults: UserDefaults) -> [UUID: SidebarClearMark] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: SidebarClearMark].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    public static func save(_ marks: [UUID: SidebarClearMark], to defaults: UserDefaults) {
        let encoded = Dictionary(uniqueKeysWithValues: marks.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) { defaults.set(data, forKey: defaultsKey) }
    }

    /// The rows as the sidebar draws them: a cleared top-level agent goes to
    /// History (its family with it), a cleared helper folds inside its lead.
    /// Rows whose mark no longer holds are returned in `released`.
    public static func apply(
        _ marks: [UUID: SidebarClearMark], to rows: [AgentInboxRow]
    ) -> (rows: [AgentInboxRow], released: Set<UUID>) {
        guard !marks.isEmpty else { return (rows, []) }
        let present = Set(rows.map(\.id))
        var released: Set<UUID> = []
        let parentOf = Dictionary(rows.compactMap { row in row.parentId.map { (row.id, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        // A root mark can subsume the whole family. Activity beneath it must
        // release that acknowledgement too, or a working/blocked helper would
        // stay in History despite having no mark of its own.
        for row in rows {
            var ancestor = parentOf[row.id]
            var seen: Set<UUID> = [row.id]
            while let id = ancestor, seen.insert(id).inserted {
                if let mark = marks[id] {
                    let busy: Bool
                    switch row.state {
                    case .working, .approval, .input: busy = true
                    case .failed, .ready: busy = false
                    }
                    let activity = max(row.lastActiveAt ?? row.createdAt,
                                       row.terminalEvent?.endedAt ?? row.createdAt)
                    // A blocker revealed by its own words (a lazily read
                    // transcript) releases the mark. A usage stop does not: it
                    // blocks only while usage is out LIVE, so it would bring
                    // back every cleared family each time usage ran out.
                    let cause = SidebarRecovery.cause(for: row)
                    if busy || row.settlementBlocked || (cause?.isBlocking == true && cause != .usageLimit)
                        || activity >= mark.clearedAt { released.insert(id) }
                }
                ancestor = parentOf[id]
            }
        }
        var clearedRoots: [UUID: Date] = [:]
        var out = rows.map { row -> AgentInboxRow in
            guard let mark = marks[row.id] else { return row }
            guard !released.contains(row.id), holds(mark, for: row) else { released.insert(row.id); return row }
            var cleared = row
            if row.parentId.map(present.contains) != true, row.lifecycle == .active {
                cleared = row.followingParent(lifecycle: .settled(at: row.terminalEvent?.endedAt ?? row.lastActiveAt ?? row.createdAt), closingSince: row.closingSince,
                                              workspaceName: row.workspaceName, workspaceId: row.workspaceId)
                clearedRoots[row.id] = row.terminalEvent?.endedAt ?? row.lastActiveAt ?? row.createdAt
            }
            cleared.isCleared = true
            return cleared
        }
        guard !clearedRoots.isEmpty else { return (out, released) }
        // Helpers travel with a cleared root, as they do with a settled one.
        func root(_ id: UUID) -> UUID? {
            var seen: Set<UUID> = [id]
            var current = id
            while let parent = parentOf[current], seen.insert(parent).inserted { current = parent }
            return current == id ? nil : current
        }
        out = out.map { row in
            guard let top = root(row.id), clearedRoots[top] != nil, row.lifecycle == .active else { return row }
            let at = row.terminalEvent?.endedAt ?? row.lastActiveAt ?? row.createdAt
            return row.followingParent(lifecycle: .settled(at: at), closingSince: row.closingSince,
                                       workspaceName: row.workspaceName, workspaceId: row.workspaceId)
        }
        return (out, released)
    }
}

// MARK: - Dogfood fixes (0.7.53): live usage and dismissible Needs-you items

extension SidebarFailureCause {
    /// A usage pause's one sidebar action: open the paused agent. Switching
    /// accounts is offered in its tile only, never here.
    public static let usageResumeTitle = "Open"
}

/// What the host knows LIVE about one CLI's usage: whether its account in use
/// is exhausted right now, and whether another signed-in account exists.
public enum SidebarUsageLive {
    public struct State: Equatable, Sendable {
        public var exhausted: Bool
        public var canSwitch: Bool
        public init(exhausted: Bool, canSwitch: Bool) {
            self.exhausted = exhausted
            self.canSwitch = canSwitch
        }
    }

    /// Usage-resume: a row is paused on usage only while ITS OWN agent holds a
    /// usage pause (set at the stop, cleared at the reset, by a later success
    /// on the same account, or by a reading under 100%). Neither another
    /// account's reading nor an old failure's words make it one.
    public static func stamp(_ rows: [AgentInboxRow], pausedAgents: Set<UUID>) -> [AgentInboxRow] {
        rows.map { row in
            var stamped = row
            stamped.usageExhaustedNow = pausedAgents.contains(row.id)
            stamped.usageCanSwitchAccount = false
            return stamped
        }
    }

    /// Stamp each row with its CLI's live state, keyed by
    /// `SidebarRecovery.providerName`. A CLI with no live reading is not
    /// exhausted: nothing is assumed from an old failure's words.
    public static func stamp(_ rows: [AgentInboxRow], states: [String: State]) -> [AgentInboxRow] {
        rows.map { row in
            let state = states[SidebarRecovery.providerName(row.harness)]
            var stamped = row
            stamped.usageExhaustedNow = state?.exhausted ?? false
            stamped.usageCanSwitchAccount = state?.canSwitch ?? false
            return stamped
        }
    }
}

/// Every Needs-you item can be dismissed. A dismissal is scoped to the projects
/// it represents and remembers the incident's fingerprint (agents and events). It stops
/// matching the moment something new happens: another agent joins, or one of
/// them fails or asks again.
public enum SidebarIncidentDismissals {
    public static let defaultsKey = "continuum.sidebar.dismissedIncidents"
    static let limit = 200

    public static func storageKey(_ incident: SidebarIncident, rows: [AgentInboxRow]) -> String {
        let participants = Set(incident.agentIDs)
        let projects = Set(rows.lazy.filter { participants.contains($0.id) }
            .map { $0.projectId?.uuidString ?? "unassigned" })
        return "projects:\(projects.sorted().joined(separator: ",")):\(incident.id)"
    }

    public static func fingerprint(_ incident: SidebarIncident, rows: [AgentInboxRow]) -> String {
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let asks = incident.kind == .needsYou
        return incident.agentIDs.map(\.uuidString).sorted().map { key -> String in
            guard let id = UUID(uuidString: key), let row = byId[id] else { return key }
            var part = "\(key):\(row.state.rawValue):\(row.terminalEvent?.sequence ?? 0)"
            if asks { part += ":\(row.lastActiveAt?.timeIntervalSince1970 ?? 0)" }
            return part
        }.joined(separator: "|")
    }

    public static func isDismissed(_ incident: SidebarIncident, dismissed: [String: String],
                                   rows: [AgentInboxRow]) -> Bool {
        // An older mark still belongs to the exact agent/event fingerprint it saved.
        guard incident.isBlocking,
              let mark = dismissed[storageKey(incident, rows: rows)] ?? dismissed[incident.id] else { return false }
        return mark == fingerprint(incident, rows: rows)
    }

    public static func visible(_ incidents: [SidebarIncident], dismissed: [String: String],
                               rows: [AgentInboxRow]) -> [SidebarIncident] {
        guard !dismissed.isEmpty else { return incidents }
        return incidents.filter { !isDismissed($0, dismissed: dismissed, rows: rows) }
    }

    public static func load(from defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    public static func save(_ dismissed: [String: String], to defaults: UserDefaults) {
        var kept = dismissed
        while kept.count > limit, let any = kept.keys.first { kept[any] = nil }
        defaults.set(kept, forKey: defaultsKey)
    }
}
