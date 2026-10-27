import Foundation

// Plan: .plans/86-workspace-filter/README.md
//
// A SET OF WORKSPACES, NOT ONE. The sidebar's scope is a checklist: any mix of
// workspaces, the one on screen as a live member, and the agents that have no
// workspace at all.
//
// INCLUDE OR EXCLUDE IS INFERRED, never asked. The two only differ for a
// workspace that does not exist yet: an include set leaves it out, an exclude
// set shows it. So the mode is where you started — unchecking from `All agents`
// builds an exclude set ("All but Film"), checking from `This workspace` builds
// an include set ("Array + Film") — and nobody is shown a mode switch.
//
// `.currentWorkspace` and `.all` are this type's two commonest values, and they
// keep their own `InboxScope` cases (and storage values) through `normalized`,
// so a sidebar that never touches the checklist stores exactly what it did.
public struct InboxWorkspaceFilter: Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable {
        case include, exclude
    }

    public var mode: Mode
    /// Include only: the workspace on screen is in the set, and follows a
    /// switch. Meaningless in an exclude set, where it is always false.
    public var followsCurrent: Bool
    /// Include: the workspaces shown. Exclude: the workspaces hidden.
    public var workspaces: Set<UUID>
    /// Agents with no workspace — a headless agent has no tile, so it lives in
    /// none (`InboxScope.matches`).
    public var showsUnplaced: Bool

    public init(mode: Mode, followsCurrent: Bool = false, workspaces: Set<UUID> = [], showsUnplaced: Bool) {
        self.mode = mode
        self.followsCurrent = mode == .include && followsCurrent
        self.workspaces = workspaces
        self.showsUnplaced = showsUnplaced
    }

    public static let all = InboxWorkspaceFilter(mode: .exclude, showsUnplaced: true)
    public static let current = InboxWorkspaceFilter(mode: .include, followsCurrent: true, showsUnplaced: false)

    /// The workspaces whose agents this set shows, `current` resolved. Exclude
    /// sets are open-ended, so they answer through `shows(workspace:)` instead.
    public func included(current: UUID?) -> Set<UUID> {
        guard mode == .include else { return [] }
        var ids = workspaces
        if followsCurrent, let current { ids.insert(current) }
        return ids
    }

    public func shows(workspace id: UUID, current: UUID?) -> Bool {
        switch mode {
        case .include: return included(current: current).contains(id)
        case .exclude: return !workspaces.contains(id)
        }
    }

    /// Whether this row belongs to the set. A row with neither a workspace ID nor a
    /// name is unplaced. A legacy name-only row has no identity a set can name, so
    /// only an exclude set — which hides by naming — keeps it.
    public func matches(_ row: AgentInboxRow, current: UUID?) -> Bool {
        if let id = row.workspaceId { return shows(workspace: id, current: current) }
        if row.workspaceName != nil { return mode == .exclude }
        return showsUnplaced
    }

    /// An include set that would show nothing. The checklist refuses to make one:
    /// unchecking the last box leaves it checked.
    public var isEmpty: Bool {
        mode == .include && !followsCurrent && workspaces.isEmpty && !showsUnplaced
    }

    // MARK: - Toggles

    /// One checkbox. In an include set, unchecking the current workspace while it
    /// is only there by following drops the follow; nil means the change would
    /// empty the set.
    public func toggling(workspace id: UUID, current: UUID?) -> InboxWorkspaceFilter? {
        var next = self
        switch mode {
        case .include:
            if included(current: current).contains(id) {
                next.workspaces.remove(id)
                if id == current { next.followsCurrent = false }
            } else {
                next.workspaces.insert(id)
            }
        case .exclude:
            if next.workspaces.contains(id) { next.workspaces.remove(id) } else { next.workspaces.insert(id) }
        }
        return next.isEmpty ? nil : next
    }

    /// `This workspace`. Checked in an exclude set, it narrows to the follow
    /// alone: that row means "the one on screen", not "add it to everything".
    public func togglingCurrent() -> InboxWorkspaceFilter? {
        guard mode == .include else { return .current }
        var next = self
        next.followsCurrent.toggle()
        return next.isEmpty ? nil : next
    }

    public func togglingUnplaced() -> InboxWorkspaceFilter? {
        var next = self
        next.showsUnplaced.toggle()
        return next.isEmpty ? nil : next
    }

    /// `Only`: this workspace and nothing else. The workspace on screen is the
    /// follow rather than a pin, so `Only` on it is `This workspace`.
    public static func only(_ id: UUID, current: UUID?) -> InboxWorkspaceFilter {
        id == current ? .current : InboxWorkspaceFilter(mode: .include, workspaces: [id], showsUnplaced: false)
    }

    /// The set with every workspace the registry no longer knows dropped, for the
    /// title and the match. Storage keeps the stored set untouched, so a workspace
    /// that comes back (an undone delete, a restored registry) is still in it. An
    /// include set left empty falls back to the workspace on screen.
    public func ignoringWorkspaces(notIn known: Set<UUID>) -> InboxWorkspaceFilter {
        var next = self
        next.workspaces.formIntersection(known)
        return next.isEmpty ? .current : next
    }

    // MARK: - Words

    /// The trigger's label. Names lead with the current workspace, then sort, so
    /// "Array + Film" does not become "Film + Array" when you switch to Array.
    public func title(names: [UUID: String], current: UUID?) -> String {
        func sorted(_ ids: Set<UUID>) -> [UUID] {
            ids.sorted { left, right in
                if left == current { return true }
                if right == current { return false }
                let l = names[left] ?? "", r = names[right] ?? ""
                let order = l.localizedCaseInsensitiveCompare(r)
                return order == .orderedSame ? left.uuidString < right.uuidString : order == .orderedAscending
            }
        }
        switch mode {
        case .include:
            let ids = sorted(included(current: current))
            var parts = ids.map { id in
                id == current && followsCurrent && ids.count == 1 && !showsUnplaced
                    ? InboxScope.currentWorkspaceTitle : names[id] ?? "Workspace"
            }
            if showsUnplaced { parts.append(InboxWorkspaceFilter.unplacedTitle) }
            switch parts.count {
            case 0: return InboxScope.currentWorkspaceTitle
            case 1: return parts[0]
            case 2: return "\(parts[0]) + \(parts[1])"
            default: return "\(parts.count) workspaces"
            }
        case .exclude:
            var parts = sorted(workspaces).map { names[$0] ?? "Workspace" }
            if !showsUnplaced { parts.append(InboxWorkspaceFilter.unplacedTitle) }
            switch parts.count {
            case 0: return InboxScope.allTitle
            case 1: return "All but \(parts[0])"
            default: return "All but \(parts.count)"
            }
        }
    }

    public static let unplacedTitle = "Unplaced"

    // MARK: - Storage

    /// `include:current,unplaced,<id>` or `exclude:unplaced,<id>`. In an exclude
    /// set the `unplaced` token means HIDDEN, matching what its ids mean there.
    var storageBody: String {
        var tokens: [String] = []
        if followsCurrent { tokens.append("current") }
        if (mode == .include) == showsUnplaced { tokens.append("unplaced") }
        tokens += workspaces.map { $0.uuidString.lowercased() }.sorted()
        return "\(mode.rawValue):\(tokens.joined(separator: ","))"
    }

    init?(storageBody: String) {
        guard let colon = storageBody.firstIndex(of: ":"),
              let mode = Mode(rawValue: String(storageBody[..<colon])) else { return nil }
        let tokens = storageBody[storageBody.index(after: colon)...].split(separator: ",").map(String.init)
        var ids = Set<UUID>()
        var follows = false, unplacedToken = false
        for token in tokens {
            switch token {
            case "current": follows = true
            case "unplaced": unplacedToken = true
            default:
                guard let id = UUID(uuidString: token) else { return nil }
                ids.insert(id)
            }
        }
        guard mode == .include || !follows else { return nil }
        self.init(mode: mode, followsCurrent: follows, workspaces: ids,
                  showsUnplaced: mode == .include ? unplacedToken : !unplacedToken)
        guard !isEmpty else { return nil }
    }
}

extension InboxScope {
    /// The set this scope is, when it is one. Projects, `This Mac` and legacy
    /// name-only workspace scopes are not sets: picking a checkbox from one of
    /// them starts again from `This workspace`.
    public var workspaceFilter: InboxWorkspaceFilter? {
        switch self {
        case .all: return .all
        case .currentWorkspace: return .current
        case .workspaceID(let id, _): return InboxWorkspaceFilter(mode: .include, workspaces: [id], showsUnplaced: false)
        case .workspaces(let filter): return filter
        case .project, .workspace, .thisMac: return nil
        }
    }

    /// The two sets that have always had their own case keep it, so their stored
    /// value never changes.
    public static func normalized(_ filter: InboxWorkspaceFilter) -> InboxScope {
        if filter == .all { return .all }
        if filter == .current { return .currentWorkspace }
        return .workspaces(filter)
    }
}
