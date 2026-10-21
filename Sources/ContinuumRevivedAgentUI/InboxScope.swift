import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P3.8-scope-dropdown.md
//
// FILTER THE FLAT LIST; DO NOT GROUP IT.
//
// Group headers would make the sidebar's width depend on the number and length of
// the project names in it, and they would also fight the locked frozen order
// (P3.4): grouping IS a reorder, applied every time an agent joins a project. A
// scope is one control at a fixed width, and it leaves the order alone — the rows
// that survive it are in exactly the positions they already held.
//
// Pure and Foundation-only, beside `InboxSort` for the same reason it is: the
// desktop's list behaviour is shared vocabulary, and this module may not import
// Core (P1.1, compiler-enforced). Persistence is Core's (`WorkspaceSidebarConfig`)
// and the popup is the view's (`AgentInboxView`); neither fact is decided here.
public enum InboxScope: Equatable, Hashable, Sendable {
    /// Everything the list was handed. The default, and the only scope that can
    /// show an agent with no project and no workspace.
    case all
    case project(String)
    case workspace(String)
    /// Stable workspace identity; the name is presentation only.
    case workspaceID(UUID, String)
    /// Whichever workspace is on screen: the default scope, following the host's
    /// stable workspace ID across switches. A legacy name is used only when the
    /// host has no ID; with neither fact available, it filters nothing.
    case currentWorkspace
    // Plan: .plans/79-session-handoff/README.md
    /// Everything, plus the sessions from other apps that every other scope
    /// leaves out: quiet ones, and ones in folders that are not projects.
    case thisMac

    /// The word on the popup entry. A project or workspace shows its own NAME and
    /// nothing else — no "Project: " prefix — because the two kinds never collide
    /// in one menu section and a prefix is width the sidebar does not have.
    public var title: String {
        switch self {
        case .all: return InboxScope.allTitle
        case .currentWorkspace: return InboxScope.currentWorkspaceTitle
        case .thisMac: return InboxScope.thisMacTitle
        case .project(let name), .workspace(let name), .workspaceID(_, let name): return name
        }
    }

    public static let allTitle = "All agents"
    public static let currentWorkspaceTitle = "This workspace"
    public static let thisMacTitle = "This Mac"

    /// What `UserDefaults` stores. TAGGED, so a project called "all" and a
    /// workspace and a project that share a name are three different scopes, and
    /// split on the FIRST colon only, so a name containing one survives the round
    /// trip.
    public var storageValue: String {
        switch self {
        case .all: return "all"
        case .currentWorkspace: return "current"
        case .thisMac: return "mac"
        case .project(let name): return "project:\(name)"
        case .workspace(let name): return "workspace:\(name)"
        case .workspaceID(let id, _): return "workspace-id:\(id.uuidString.lowercased())"
        }
    }

    /// nil for anything this version did not write — an empty name, an unknown
    /// tag, a truncated value. The caller (`WorkspaceSidebarConfig.resolveScope`)
    /// turns that into `.all`, which is the only safe default: a scope that cannot
    /// be understood must not hide rows.
    public init?(storageValue: String) {
        if storageValue == "all" {
            self = .all
            return
        }
        if storageValue == "current" {
            self = .currentWorkspace
            return
        }
        if storageValue == "mac" {
            self = .thisMac
            return
        }
        guard let separator = storageValue.firstIndex(of: ":") else { return nil }
        let name = String(storageValue[storageValue.index(after: separator)...])
        guard !name.isEmpty else { return nil }
        switch storageValue[storageValue.startIndex..<separator] {
        case "project": self = .project(name)
        case "workspace": self = .workspace(name)
        case "workspace-id":
            guard let id = UUID(uuidString: name) else { return nil }
            self = .workspaceID(id, id.uuidString)
        default: return nil
        }
    }

    /// Whether this row belongs to the scope.
    ///
    /// A row whose `projectName` or `workspaceName` is nil is in `.all` and in
    /// nothing else. That is honest rather than convenient: a headless agent
    /// (P2A.6) has no tile, so `AgentRowContext.workspaceName` is nil for it by
    /// documented design — it lives in no workspace, and a workspace scope that
    /// silently kept it would be claiming otherwise. `.all` is where it is found.
    public func matches(_ row: AgentInboxRow) -> Bool {
        switch self {
        case .all, .currentWorkspace, .thisMac: return true
        case .project(let name): return row.projectName == name
        case .workspace(let name): return row.workspaceName == name
        case .workspaceID(let id, _): return row.workspaceId == id
        }
    }

    /// The menu: `All agents`, then one entry per project, then one per workspace —
    /// each block sorted by name, case-insensitively, because the popup is read
    /// alphabetically and `Zed` before `apps` is a list you have to search.
    ///
    /// Projects before workspaces, and never merged into one sorted block: a
    /// project is the scope you want nine times out of ten (it is where the work
    /// is), so it is the one nearer the top of the menu.
    ///
    /// `catalog` is what is OPEN — every project and workspace the registry knows,
    /// handed in by the host. It is not optional decoration: the packet asks for
    /// "one entry per open project · one per workspace", and a menu derived from the
    /// rows alone cannot offer a project you have open with no agent running in it,
    /// which is exactly the project you are about to start one in. (Found in
    /// cross-review.) The rows are still read as well, so an agent whose project has
    /// left the registry — a checkout that went missing under a live agent — is still
    /// reachable by name.
    ///
    /// `including` is the scope currently SELECTED. It is appended if neither the
    /// catalog nor the rows mention it — a project that was renamed or removed while
    /// it was the selected scope. The alternative is a popup whose selection is not
    /// in its own menu, which AppKit renders as the first entry: the list would
    /// silently show one scope and the control would claim another. An empty list
    /// under a stale scope is the honest reading, and `AgentInboxView` labels it as
    /// one.
    ///
    /// Workspace scopes use stable IDs whenever available. Legacy rows/scopes
    /// without IDs retain their name-based behavior for compatibility.
    ///
    /// `offersThisMac` adds `This Mac` after `All agents`, for a host that lists
    /// sessions from other apps; without one the entry would only repeat `All`.
    public static func entries(
        for rows: [AgentInboxRow],
        catalog: [InboxScope] = [],
        including selected: InboxScope = .all,
        currentWorkspace: String? = nil,
        currentWorkspaceId: UUID? = nil,
        offersThisMac: Bool = false
    ) -> [InboxScope] {
        var projectNames = rows.compactMap(\.projectName)
        var workspaceNames = rows.filter { $0.workspaceId == nil }.compactMap(\.workspaceName)
        let rowWorkspacePairs: [(UUID, String)] = rows.compactMap { row in
            guard let id = row.workspaceId, let name = row.workspaceName else { return nil }
            return (id, name)
        }
        var workspacesById: [UUID: String] = Dictionary(
            rowWorkspacePairs, uniquingKeysWith: { first, _ in first })
        for scope in catalog {
            switch scope {
            case .project(let name): projectNames.append(name)
            case .workspace(let name): workspaceNames.append(name)
            case .workspaceID(let id, let name): workspacesById[id] = name
            case .all, .currentWorkspace, .thisMac: break
            }
        }
        // "This workspace" leads when the host knows which one is on screen.
        let idWorkspaceEntries: [InboxScope] = workspacesById.map {
            InboxScope.workspaceID($0.key, $0.value)
        }
        let sortedIDWorkspaceEntries: [InboxScope] = idWorkspaceEntries.sorted { left, right in
            let order = left.title.localizedCaseInsensitiveCompare(right.title)
            return order == .orderedSame
                ? left.storageValue < right.storageValue
                : order == .orderedAscending
        }
        var entries: [InboxScope] =
            (currentWorkspace == nil && currentWorkspaceId == nil ? [] : [.currentWorkspace])
            + [.all]
            + (offersThisMac ? [.thisMac] : [])
            + names(projectNames).map(InboxScope.project)
            + sortedIDWorkspaceEntries
            + names(workspaceNames).map(InboxScope.workspace)
        if !entries.contains(where: { $0.storageValue == selected.storageValue }) { entries.append(selected) }
        return entries
    }

    private static func names(_ values: [String]) -> [String] {
        Set(values).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The rows a scope leaves on screen, IN THE ORDER THEY ARRIVED. Filtering is
    /// not ranking: `InboxSort` owns the order (P3.4) and this composes on either
    /// side of it without changing what it decided.
    ///
    /// `openAgentId` is FORCE-INCLUDED whatever the scope says — the agent open in
    /// the focused tile. Without it, opening an agent from one project and then
    /// scoping to another hides the row for the thing you are looking at, which is
    /// the one row that must always be reachable. It is the caller's fact (a
    /// focused tile is not something a pure value can know) and nil when nothing
    /// is focused.
    public static func filter(
        rows: [AgentInboxRow],
        scope: InboxScope,
        openAgentId: UUID? = nil,
        currentWorkspace: String? = nil,
        currentWorkspaceId: UUID? = nil
    ) -> [AgentInboxRow] {
        // A session from another app shows outside "This Mac" only while it is
        // live or waiting on you, in one of this workspace's projects.
        guard scope != .thisMac else { return rows }
        let rows = rows.filter { $0.externalSession?.isProminent ?? true }
        let resolved: InboxScope
        if scope == .currentWorkspace {
            if let currentWorkspaceId {
                resolved = .workspaceID(currentWorkspaceId, currentWorkspace ?? currentWorkspaceId.uuidString)
            } else if let currentWorkspace {
                resolved = .workspace(currentWorkspace)
            } else { return rows }
        } else {
            resolved = scope
        }
        guard resolved != .all else { return rows }
        return rows.filter { $0.id == openAgentId || resolved.matches($0) }
    }
}
