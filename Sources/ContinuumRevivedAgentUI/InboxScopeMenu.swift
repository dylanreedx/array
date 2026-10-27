import Foundation

// Plan: .plans/86-workspace-filter/README.md
//
// THE CHECKLIST, AS DATA. What the scope popover lists, what each box shows, and
// what a click on each one does — pure, so the toggle rules are witnessed without a
// window (`InboxScopeChecks`) and the view only paints them.
//
// Two kinds of row. Workspaces with an identity, `This workspace` and `Unplaced`
// are CHECKBOXES over one `InboxWorkspaceFilter`. `All agents`, `This Mac`,
// projects and legacy name-only workspaces are PICKS: choosing one replaces the
// scope, and choosing the one already showing does nothing. Projects stay picks on
// purpose (Dylan, 2026-10-26: not checkable).
public struct InboxScopeMenuEntry: Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case current, all, thisMac, workspace(UUID), unplaced, project(String), legacyWorkspace(String)
    }

    public enum Check: Equatable, Sendable {
        case on, off, mixed
        /// In the set only because it is the workspace on screen: the follow, not
        /// a pin. Drawn as a faint check.
        case following
    }

    /// Which block the row sits in; the view draws a divider where it changes.
    public enum Section: Int, Sendable {
        case pinned, workspaces, unplaced, picks
    }

    public let kind: Kind
    public let title: String
    /// "4 agents · 1 needs you" under a workspace.
    public let detail: String?
    /// Right-aligned caption: the current workspace's name on `This workspace`.
    public let trailing: String?
    public let check: Check
    public let needsYou: Bool
    public let section: Section

    /// The scope's own storage value where it has one, so a pick is addressed by the
    /// same string the setting stores.
    public var id: String {
        switch kind {
        case .current: return InboxScope.currentWorkspace.storageValue
        case .all: return InboxScope.all.storageValue
        case .thisMac: return InboxScope.thisMac.storageValue
        case .workspace(let id): return InboxScope.workspaceID(id, "").storageValue
        case .unplaced: return "unplaced"
        case .project(let name): return InboxScope.project(name).storageValue
        case .legacyWorkspace(let name): return InboxScope.workspace(name).storageValue
        }
    }

    /// Whether choosing this row keeps the popover open. Checkboxes do; picks close it.
    public var isToggle: Bool {
        switch kind {
        case .current, .workspace, .unplaced: return true
        case .all, .thisMac, .project, .legacyWorkspace: return false
        }
    }
}

public enum InboxScopeMenu {
    public struct Workspace: Equatable, Sendable {
        public let id: UUID
        public let name: String
        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The rows, in order: pinned, workspaces (current first, then by name),
    /// `Unplaced` when any agent has no workspace, then the picks.
    ///
    /// `workspaces` is the registry's; a workspace the rows mention that it lacks is
    /// added so its agents stay reachable. Projects come from the catalog and the
    /// rows, as `InboxScope.entries` always did.
    public static func entries(
        scope: InboxScope,
        workspaces: [Workspace],
        projects: [String] = [],
        legacyWorkspaces: [String] = [],
        rows: [AgentInboxRow],
        current: UUID?,
        offersCurrent: Bool? = nil,
        offersThisMac: Bool = false
    ) -> [InboxScopeMenuEntry] {
        let filter = scope.workspaceFilter
        var known = workspaces
        for row in rows {
            guard let id = row.workspaceId, !known.contains(where: { $0.id == id }) else { continue }
            known.append(Workspace(id: id, name: row.workspaceName ?? "Workspace"))
        }
        known.sort { left, right in
            if left.id == current { return right.id != current }
            if right.id == current { return false }
            let order = left.name.localizedCaseInsensitiveCompare(right.name)
            return order == .orderedSame ? left.id.uuidString < right.id.uuidString : order == .orderedAscending
        }
        let active = rows.filter { $0.lifecycle == .active }
        func tally(_ rows: [AgentInboxRow]) -> (detail: String, needsYou: Bool) {
            let needs = rows.filter { $0.state == .approval || $0.state == .input }.count
            var detail = rows.count == 1 ? "1 agent" : "\(rows.count) agents"
            if needs > 0 { detail += " · \(needs) needs you" }
            return (detail, needs > 0)
        }

        var entries: [InboxScopeMenuEntry] = []
        let currentName = known.first { $0.id == current }?.name
        if offersCurrent ?? (current != nil) {
            entries.append(InboxScopeMenuEntry(
                kind: .current, title: InboxScope.currentWorkspaceTitle, detail: nil, trailing: currentName,
                check: filter.map { $0.mode == .include && $0.followsCurrent ? .on : .off } ?? .off,
                needsYou: false, section: .pinned))
        }
        let allCheck: InboxScopeMenuEntry.Check
        if scope == .all { allCheck = .on } else if filter?.mode == .exclude { allCheck = .mixed } else { allCheck = .off }
        entries.append(InboxScopeMenuEntry(
            kind: .all, title: InboxScope.allTitle, detail: nil, trailing: nil, check: allCheck,
            needsYou: false, section: .pinned))
        if offersThisMac {
            entries.append(InboxScopeMenuEntry(
                kind: .thisMac, title: InboxScope.thisMacTitle, detail: nil, trailing: nil,
                check: scope == .thisMac ? .on : .off, needsYou: false, section: .pinned))
        }
        for workspace in known {
            let check: InboxScopeMenuEntry.Check
            if let filter {
                switch filter.mode {
                case .include:
                    if filter.workspaces.contains(workspace.id) { check = .on }
                    else if filter.followsCurrent && workspace.id == current { check = .following }
                    else { check = .off }
                case .exclude:
                    check = filter.workspaces.contains(workspace.id) ? .off : .on
                }
            } else {
                check = .off
            }
            let counts = tally(active.filter { $0.workspaceId == workspace.id })
            entries.append(InboxScopeMenuEntry(
                kind: .workspace(workspace.id), title: workspace.name, detail: counts.detail, trailing: nil,
                check: check, needsYou: counts.needsYou, section: .workspaces))
        }
        let unplaced = active.filter { $0.workspaceId == nil && $0.workspaceName == nil }
        if !unplaced.isEmpty || filter?.showsUnplaced == true && filter?.mode == .include {
            entries.append(InboxScopeMenuEntry(
                kind: .unplaced, title: InboxWorkspaceFilter.unplacedTitle, detail: nil,
                trailing: unplaced.count == 1 ? "1 headless" : "\(unplaced.count) headless",
                check: filter?.showsUnplaced == true ? .on : .off, needsYou: false, section: .unplaced))
        }
        let projectNames = Set(projects + rows.compactMap(\.projectName))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for name in projectNames {
            entries.append(InboxScopeMenuEntry(
                kind: .project(name), title: name, detail: nil, trailing: nil,
                check: scope == .project(name) ? .on : .off, needsYou: false, section: .picks))
        }
        let legacy = Set(legacyWorkspaces + rows.filter { $0.workspaceId == nil }.compactMap(\.workspaceName))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for name in legacy {
            entries.append(InboxScopeMenuEntry(
                kind: .legacyWorkspace(name), title: name, detail: nil, trailing: nil,
                check: scope == .workspace(name) ? .on : .off, needsYou: false, section: .picks))
        }
        // A pick that is selected but no longer listed — a renamed project — stays in
        // the menu, so the trigger never names a scope its own menu lacks.
        switch scope {
        case .project(let name) where !projectNames.contains(name):
            entries.append(InboxScopeMenuEntry(
                kind: .project(name), title: name, detail: nil, trailing: nil, check: .on,
                needsYou: false, section: .picks))
        case .workspace(let name) where !legacy.contains(name):
            entries.append(InboxScopeMenuEntry(
                kind: .legacyWorkspace(name), title: name, detail: nil, trailing: nil, check: .on,
                needsYou: false, section: .picks))
        default: break
        }
        return entries
    }

    /// What a click on `kind` makes the scope. nil means nothing changes: a pick
    /// already showing, or a checkbox whose unchecking would empty the set.
    ///
    /// `only` is the `Only` pill and Option-click: the row's workspace alone.
    public static func choose(
        _ kind: InboxScopeMenuEntry.Kind, from scope: InboxScope, current: UUID?, only: Bool = false
    ) -> InboxScope? {
        let next: InboxScope?
        // A checkbox clicked from a scope that is not a set starts from the default.
        let filter = scope.workspaceFilter ?? .current
        switch kind {
        case .all: next = .all
        case .thisMac: next = .thisMac
        case .project(let name): next = .project(name)
        case .legacyWorkspace(let name): next = .workspace(name)
        case .current:
            if only || scope.workspaceFilter == nil { next = .currentWorkspace }
            else { next = filter.togglingCurrent().map(InboxScope.normalized) }
        case .workspace(let id):
            if only { next = InboxScope.normalized(.only(id, current: current)) }
            else { next = filter.toggling(workspace: id, current: current).map(InboxScope.normalized) }
        case .unplaced:
            if only { next = .workspaces(InboxWorkspaceFilter(mode: .include, showsUnplaced: true)) }
            else { next = filter.togglingUnplaced().map(InboxScope.normalized) }
        }
        guard let next, next != scope else { return nil }
        return next
    }

    /// The trigger's label for any scope, with the registry's names.
    public static func title(for scope: InboxScope, names: [UUID: String], current: UUID?) -> String {
        switch scope {
        case .workspaces(let filter): return filter.title(names: names, current: current)
        case .workspaceID(let id, let name): return names[id] ?? name
        default: return scope.title
        }
    }

    /// The workspaces whose agents the scope shows, for the trigger's dots and the
    /// cards' edge marks — empty unless that is more than one. An exclude set
    /// answers from `known`, since it is open-ended.
    public static func visibleWorkspaces(for scope: InboxScope, known: [UUID], current: UUID?) -> [UUID] {
        guard let filter = scope.workspaceFilter else { return [] }
        let visible = known.filter { filter.shows(workspace: $0, current: current) }
        return visible.count > 1 ? visible : []
    }
}
