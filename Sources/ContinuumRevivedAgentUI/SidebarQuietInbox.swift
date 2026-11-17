import Foundation

// Sidebar round (array/sidebar-next), the "Quiet inbox" layout (variants/A).
// Today's rows stay as they are. The head adds two things on the shared core
// (SidebarLedgerCore): a "Needs you" box that exists only while something
// blocks you, and one cause chip with one action per family. Pure, so the
// AgentUI checks and the app's witness read the same answers.

public enum SidebarQuietInbox {
    /// One family's cause: the chip ("7 paused · usage") and its one action.
    public struct FamilyChip: Equatable, Sendable {
        public let familyId: UUID
        public let familyTitle: String
        public let cause: SidebarFailureCause
        /// Agents in the family carrying this cause.
        public let count: Int
        /// "7 paused · usage", "2 failed · Codex was busy".
        public let text: String
        /// The family-scoped incident the action acts on: its agents, owners
        /// and family are this family's only.
        public let incident: SidebarIncident
    }

    /// The box's lines: blocking incidents only, in the core's order. Empty
    /// means there is no box at all, never an empty-state row.
    public static func needsYou(_ incidents: [SidebarIncident]) -> [SidebarIncident] {
        incidents.filter(\.isBlocking)
    }

    /// One chip per family that carries a cause, in list order. A family with
    /// more than one cause shows the one touching the most agents, blocking
    /// first on a tie, so each family has exactly one chip and one action.
    public static func familyChips(rows: [AgentInboxRow]) -> [FamilyChip] {
        let live = rows.filter { $0.lifecycle == .active && !$0.isCleared }
        let byId = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func root(of row: AgentInboxRow) -> AgentInboxRow {
            var current = row
            var seen: Set<UUID> = [row.id]
            while let parent = current.parentId.flatMap({ byId[$0] }), seen.insert(parent.id).inserted {
                current = parent
            }
            return current
        }
        var order: [UUID] = []
        var members: [UUID: [AgentInboxRow]] = [:]
        for row in live {
            let family = root(of: row)
            if members[family.id] == nil { order.append(family.id) }
            members[family.id, default: []].append(row)
        }
        let causeOrder = SidebarFailureCause.allCases
        return order.compactMap { familyId -> FamilyChip? in
            guard let family = byId[familyId], let rows = members[familyId] else { return nil }
            // Count by cause across providers: a family's usage pause is one
            // chip whether its helpers run on one CLI or two.
            // Counted over the lead's members only, exactly as `SidebarLeadTally`
            // counts them: the lead's own state is its own row's, never a
            // helper count, so both layouts say the same number for one lead.
            var carriers: [SidebarFailureCause: [AgentInboxRow]] = [:]
            for row in rows where row.id != familyId {
                if let cause = SidebarRecovery.cause(for: row) { carriers[cause, default: []].append(row) }
            }
            guard let topCause = carriers.keys.max(by: { lhs, rhs in
                let l = carriers[lhs]!.count, r = carriers[rhs]!.count
                if l != r { return l < r }
                if lhs.isBlocking != rhs.isBlocking { return !lhs.isBlocking }
                return causeOrder.firstIndex(of: lhs)! > causeOrder.firstIndex(of: rhs)!
            }), let carrying = carriers[topCause] else { return nil }
            // The core's incidents for this cause, family-scoped: owners resolve
            // through the family's own leads.
            let incidents = SidebarIncidents.build(rows: rows).filter { $0.kind == .cause(topCause) }
            guard let first = incidents.first else { return nil }
            func unique(_ ids: [UUID]) -> [UUID] {
                var seen: Set<UUID> = []
                return ids.filter { seen.insert($0).inserted }
            }
            let harnesses = Set(carrying.map { $0.harness ?? "" })
            let harness = harnesses.count == 1 ? carrying[0].harness : nil
            let text = chipText(cause: topCause, count: carrying.count, harness: harness, rows: carrying)
            let scoped = SidebarIncident(
                id: "family:\(familyId.uuidString):\(topCause.rawValue)", kind: .cause(topCause),
                symbol: first.symbol, title: family.displayTitle, detail: text,
                actionTitle: incidents.allSatisfy({ $0.actionTitle == first.actionTitle })
                    ? first.actionTitle : topCause.actionTitle,
                agentIDs: unique(incidents.flatMap(\.agentIDs)), ownerIDs: unique(incidents.flatMap(\.ownerIDs)),
                familyIDs: [familyId], harness: harness)
            return FamilyChip(familyId: familyId, familyTitle: family.displayTitle, cause: topCause,
                              count: carrying.count, text: text, incident: scoped)
        }
    }

    /// The chip's words. The count is said once, in the state the core counts
    /// the agents in (a usage stop is paused, never failed).
    public static func chipText(
        cause: SidebarFailureCause, count: Int, harness: String?, rows: [AgentInboxRow]
    ) -> String {
        let provider = SidebarRecovery.providerName(harness)
        switch cause {
        case .usageLimit: return "\(count) paused · usage"
        case .providerBusy: return "\(count) failed · \(provider) was busy"
        case .signInExpired: return "\(count) failed · sign-in expired"
        case .couldNotStart: return "\(count) failed · \(provider) couldn't start"
        case .interruptedByRestart: return "\(count) interrupted by restart"
        case .taskError:
            if count == 1, let first = rows.first, let reason = SidebarRecovery.shortReason(first, maxCharacters: 48) {
                return "1 failed · \(reason)"
            }
            return "\(count) failed"
        }
    }
}
